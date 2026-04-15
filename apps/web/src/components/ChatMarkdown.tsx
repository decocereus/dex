import { DiffsHighlighter, getSharedHighlighter, SupportedLanguages } from "@pierre/diffs";
import { CheckIcon, CopyIcon } from "lucide-react";
import React, {
  Children,
  Suspense,
  isValidElement,
  use,
  useCallback,
  memo,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { Components } from "react-markdown";
import ReactMarkdown from "react-markdown";
import { defaultUrlTransform } from "react-markdown";
import remarkGfm from "remark-gfm";
import { openInPreferredEditor } from "../editorPreferences";
import { readEnvironmentApi } from "../environmentApi";
import { resolveDiffThemeName, type DiffThemeName } from "../lib/diffRendering";
import { fnv1a32 } from "../lib/diffRendering";
import { LRUCache } from "../lib/lruCache";
import { useTheme } from "../hooks/useTheme";
import { resolveMarkdownFileLinkTarget, rewriteMarkdownFileUriHref } from "../markdown-links";
import { readLocalApi } from "../localApi";
import { toastManager } from "./ui/toast";
import type { EnvironmentId } from "@dex/contracts";

class CodeHighlightErrorBoundary extends React.Component<
  { fallback: ReactNode; children: ReactNode },
  { hasError: boolean }
> {
  constructor(props: { fallback: ReactNode; children: ReactNode }) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError() {
    return { hasError: true };
  }

  override render() {
    if (this.state.hasError) {
      return this.props.fallback;
    }
    return this.props.children;
  }
}

interface ChatMarkdownProps {
  text: string;
  cwd: string | undefined;
  environmentId?: EnvironmentId | undefined;
  isStreaming?: boolean;
}

const CODE_FENCE_LANGUAGE_REGEX = /(?:^|\s)language-([^\s]+)/;
const MAX_HIGHLIGHT_CACHE_ENTRIES = 500;
const MAX_HIGHLIGHT_CACHE_MEMORY_BYTES = 50 * 1024 * 1024;
const highlightedCodeCache = new LRUCache<string>(
  MAX_HIGHLIGHT_CACHE_ENTRIES,
  MAX_HIGHLIGHT_CACHE_MEMORY_BYTES,
);
const highlighterPromiseCache = new Map<string, Promise<DiffsHighlighter>>();

function extractFenceLanguage(className: string | undefined): string {
  const match = className?.match(CODE_FENCE_LANGUAGE_REGEX);
  const raw = match?.[1] ?? "text";
  // Shiki doesn't bundle a gitignore grammar; ini is a close match (#685)
  return raw === "gitignore" ? "ini" : raw;
}

function nodeToPlainText(node: ReactNode): string {
  if (typeof node === "string" || typeof node === "number") {
    return String(node);
  }
  if (Array.isArray(node)) {
    return node.map((child) => nodeToPlainText(child)).join("");
  }
  if (isValidElement<{ children?: ReactNode }>(node)) {
    return nodeToPlainText(node.props.children);
  }
  return "";
}

function extractCodeBlock(
  children: ReactNode,
): { className: string | undefined; code: string } | null {
  const childNodes = Children.toArray(children);
  if (childNodes.length !== 1) {
    return null;
  }

  const onlyChild = childNodes[0];
  if (
    !isValidElement<{ className?: string; children?: ReactNode }>(onlyChild) ||
    onlyChild.type !== "code"
  ) {
    return null;
  }

  return {
    className: onlyChild.props.className,
    code: nodeToPlainText(onlyChild.props.children),
  };
}

function createHighlightCacheKey(code: string, language: string, themeName: DiffThemeName): string {
  return `${fnv1a32(code).toString(36)}:${code.length}:${language}:${themeName}`;
}

function estimateHighlightedSize(html: string, code: string): number {
  return Math.max(html.length * 2, code.length * 3);
}

function getHighlighterPromise(language: string): Promise<DiffsHighlighter> {
  const cached = highlighterPromiseCache.get(language);
  if (cached) return cached;

  const promise = getSharedHighlighter({
    themes: [resolveDiffThemeName("dark"), resolveDiffThemeName("light")],
    langs: [language as SupportedLanguages],
    preferredHighlighter: "shiki-js",
  }).catch((err) => {
    highlighterPromiseCache.delete(language);
    if (language === "text") {
      // "text" itself failed — Shiki cannot initialize at all, surface the error
      throw err;
    }
    // Language not supported by Shiki — fall back to "text"
    return getHighlighterPromise("text");
  });
  highlighterPromiseCache.set(language, promise);
  return promise;
}

function MarkdownCodeBlock({ code, children }: { code: string; children: ReactNode }) {
  const [copied, setCopied] = useState(false);
  const copiedTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const handleCopy = useCallback(() => {
    if (typeof navigator === "undefined" || navigator.clipboard == null) {
      return;
    }
    void navigator.clipboard
      .writeText(code)
      .then(() => {
        if (copiedTimerRef.current != null) {
          clearTimeout(copiedTimerRef.current);
        }
        setCopied(true);
        copiedTimerRef.current = setTimeout(() => {
          setCopied(false);
          copiedTimerRef.current = null;
        }, 1200);
      })
      .catch(() => undefined);
  }, [code]);

  useEffect(
    () => () => {
      if (copiedTimerRef.current != null) {
        clearTimeout(copiedTimerRef.current);
        copiedTimerRef.current = null;
      }
    },
    [],
  );

  return (
    <div className="chat-markdown-codeblock leading-snug">
      <button
        type="button"
        className="chat-markdown-copy-button"
        onClick={handleCopy}
        title={copied ? "Copied" : "Copy code"}
        aria-label={copied ? "Copied" : "Copy code"}
      >
        {copied ? <CheckIcon className="size-3" /> : <CopyIcon className="size-3" />}
      </button>
      {children}
    </div>
  );
}

interface SuspenseShikiCodeBlockProps {
  className: string | undefined;
  code: string;
  themeName: DiffThemeName;
  isStreaming: boolean;
}

function SuspenseShikiCodeBlock({
  className,
  code,
  themeName,
  isStreaming,
}: SuspenseShikiCodeBlockProps) {
  const language = extractFenceLanguage(className);
  const cacheKey = createHighlightCacheKey(code, language, themeName);
  const cachedHighlightedHtml = !isStreaming ? highlightedCodeCache.get(cacheKey) : null;

  if (cachedHighlightedHtml != null) {
    return (
      <div
        className="chat-markdown-shiki"
        dangerouslySetInnerHTML={{ __html: cachedHighlightedHtml }}
      />
    );
  }

  const highlighter = use(getHighlighterPromise(language));
  const highlightedHtml = useMemo(() => {
    try {
      return highlighter.codeToHtml(code, { lang: language, theme: themeName });
    } catch (error) {
      // Log highlighting failures for debugging while falling back to plain text
      console.warn(
        `Code highlighting failed for language "${language}", falling back to plain text.`,
        error instanceof Error ? error.message : error,
      );
      // If highlighting fails for this language, render as plain text
      return highlighter.codeToHtml(code, { lang: "text", theme: themeName });
    }
  }, [code, highlighter, language, themeName]);

  useEffect(() => {
    if (!isStreaming) {
      highlightedCodeCache.set(
        cacheKey,
        highlightedHtml,
        estimateHighlightedSize(highlightedHtml, code),
      );
    }
  }, [cacheKey, code, highlightedHtml, isStreaming]);

  return (
    <div className="chat-markdown-shiki" dangerouslySetInnerHTML={{ __html: highlightedHtml }} />
  );
}

function normalizeWorkspaceSearchQuery(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return "";
  }

  const withoutHash = trimmed.split("#")[0] ?? trimmed;
  const withoutQuery = withoutHash.split("?")[0] ?? withoutHash;
  const withoutPosition = withoutQuery.replace(/:\d+(?::\d+)?$/, "");
  const normalized = withoutPosition.split("/").at(-1) ?? withoutPosition;
  return normalized.trim();
}

function scoreWorkspaceEntryMatch(entryPath: string, query: string): number {
  const normalizedPath = entryPath.toLowerCase();
  const normalizedQuery = query.toLowerCase();
  const basename = normalizedPath.split("/").at(-1) ?? normalizedPath;

  if (basename === normalizedQuery) return 5;
  if (basename.startsWith(normalizedQuery)) return 4;
  if (basename.includes(normalizedQuery)) return 3;
  if (normalizedPath.includes(`/${normalizedQuery}`)) return 2;
  if (normalizedPath.includes(normalizedQuery)) return 1;
  return 0;
}

async function resolveWorkspaceSearchedFileLinkTarget(input: {
  cwd: string | undefined;
  environmentId: EnvironmentId | undefined;
  href: string | undefined;
  linkText: string;
}): Promise<string | null> {
  if (!input.cwd || !input.environmentId) {
    return null;
  }

  const environmentApi = readEnvironmentApi(input.environmentId);
  if (!environmentApi) {
    return null;
  }

  const queryCandidates = [
    normalizeWorkspaceSearchQuery(input.href ?? ""),
    normalizeWorkspaceSearchQuery(input.linkText),
  ].filter(
    (value, index, array): value is string => value.length > 0 && array.indexOf(value) === index,
  );

  for (const query of queryCandidates) {
    const result = await environmentApi.projects.searchEntries({
      cwd: input.cwd,
      query,
      limit: 20,
    });
    const bestMatch = result.entries
      .filter((entry) => entry.kind === "file")
      .map((entry) => ({ entry, score: scoreWorkspaceEntryMatch(entry.path, query) }))
      .filter((candidate) => candidate.score > 0)
      .toSorted(
        (left, right) =>
          right.score - left.score || left.entry.path.length - right.entry.path.length,
      )[0];

    if (bestMatch) {
      const directTarget = resolveMarkdownFileLinkTarget(bestMatch.entry.path, input.cwd);
      if (directTarget) {
        return directTarget;
      }
    }
  }

  return null;
}

function ChatMarkdown({ text, cwd, environmentId, isStreaming = false }: ChatMarkdownProps) {
  const { resolvedTheme } = useTheme();
  const diffThemeName = resolveDiffThemeName(resolvedTheme);
  const markdownUrlTransform = useCallback((href: string) => {
    return rewriteMarkdownFileUriHref(href) ?? defaultUrlTransform(href);
  }, []);
  const markdownComponents = useMemo<Components>(
    () => ({
      a({ node: _node, href, children, ...props }) {
        const targetPath = resolveMarkdownFileLinkTarget(href, cwd);
        if (!targetPath) {
          const linkText = nodeToPlainText(children);
          const hasWorkspaceFallback =
            Boolean(cwd) &&
            Boolean(environmentId) &&
            normalizeWorkspaceSearchQuery(href ?? "").length > 0;

          if (!hasWorkspaceFallback) {
            return <a {...props} href={href} target="_blank" rel="noopener noreferrer" />;
          }

          return (
            <a
              {...props}
              href={href}
              onClick={(event) => {
                event.preventDefault();
                event.stopPropagation();
                const api = readLocalApi();
                if (!api) {
                  toastManager.add({
                    type: "error",
                    title: "Editor opening is unavailable.",
                  });
                  return;
                }
                void resolveWorkspaceSearchedFileLinkTarget({
                  cwd,
                  environmentId,
                  href,
                  linkText,
                })
                  .then((resolvedTargetPath) => {
                    if (!resolvedTargetPath) {
                      toastManager.add({
                        type: "error",
                        title: "Unable to find file",
                        description:
                          linkText.trim() ||
                          href?.trim() ||
                          "The linked file could not be resolved.",
                      });
                      return;
                    }
                    return openInPreferredEditor(api, resolvedTargetPath);
                  })
                  .catch((error) => {
                    toastManager.add({
                      type: "error",
                      title: "Unable to open file",
                      description: error instanceof Error ? error.message : "An error occurred.",
                    });
                  });
              }}
            >
              {children}
            </a>
          );
        }

        return (
          <a
            {...props}
            href={href}
            onClick={(event) => {
              event.preventDefault();
              event.stopPropagation();
              const api = readLocalApi();
              if (api) {
                void openInPreferredEditor(api, targetPath).catch((error) => {
                  toastManager.add({
                    type: "error",
                    title: "Unable to open file",
                    description: error instanceof Error ? error.message : "An error occurred.",
                  });
                });
              } else {
                toastManager.add({
                  type: "error",
                  title: "Editor opening is unavailable.",
                });
              }
            }}
          />
        );
      },
      pre({ node: _node, children, ...props }) {
        const codeBlock = extractCodeBlock(children);
        if (!codeBlock) {
          return <pre {...props}>{children}</pre>;
        }

        return (
          <MarkdownCodeBlock code={codeBlock.code}>
            <CodeHighlightErrorBoundary fallback={<pre {...props}>{children}</pre>}>
              <Suspense fallback={<pre {...props}>{children}</pre>}>
                <SuspenseShikiCodeBlock
                  className={codeBlock.className}
                  code={codeBlock.code}
                  themeName={diffThemeName}
                  isStreaming={isStreaming}
                />
              </Suspense>
            </CodeHighlightErrorBoundary>
          </MarkdownCodeBlock>
        );
      },
    }),
    [cwd, diffThemeName, environmentId, isStreaming],
  );

  return (
    <div className="chat-markdown w-full min-w-0 text-sm leading-relaxed text-foreground/80">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={markdownComponents}
        urlTransform={markdownUrlTransform}
      >
        {text}
      </ReactMarkdown>
    </div>
  );
}

export default memo(ChatMarkdown);
