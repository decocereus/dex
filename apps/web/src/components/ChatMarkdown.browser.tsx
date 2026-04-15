import "../index.css";

import { page } from "vitest/browser";
import { afterEach, describe, expect, it, vi } from "vitest";
import { render } from "vitest-browser-react";

const { openInPreferredEditorMock, readLocalApiMock } = vi.hoisted(() => ({
  openInPreferredEditorMock: vi.fn(async () => "vscode"),
  readLocalApiMock: vi.fn(() => ({
    server: { getConfig: vi.fn(async () => ({ availableEditors: ["vscode"] })) },
    shell: { openInEditor: vi.fn(async () => undefined) },
  })),
}));

const { readEnvironmentApiMock } = vi.hoisted(() => ({
  readEnvironmentApiMock: vi.fn(() => ({
    projects: {
      searchEntries: vi.fn(async () => ({
        entries: [{ path: ".plans/21-ios-dex-first-cutover-roadmap.md", kind: "file" }],
        truncated: false,
      })),
    },
  })),
}));

vi.mock("../editorPreferences", () => ({
  openInPreferredEditor: openInPreferredEditorMock,
}));

vi.mock("../localApi", () => ({
  ensureLocalApi: vi.fn(() => {
    throw new Error("ensureLocalApi not implemented in browser test");
  }),
  readLocalApi: readLocalApiMock,
}));

vi.mock("../environmentApi", () => ({
  readEnvironmentApi: readEnvironmentApiMock,
}));

import ChatMarkdown from "./ChatMarkdown";

describe("ChatMarkdown", () => {
  afterEach(() => {
    openInPreferredEditorMock.mockClear();
    readLocalApiMock.mockClear();
    readEnvironmentApiMock.mockClear();
    localStorage.clear();
    document.body.innerHTML = "";
  });

  it("rewrites file uri hrefs into direct paths before rendering", async () => {
    const filePath =
      "/Users/yashsingh/p/sco/claude-code-extract/src/utils/permissions/PermissionRule.ts";
    const screen = await render(
      <ChatMarkdown text={`[PermissionRule.ts](file://${filePath})`} cwd="/repo/project" />,
    );

    try {
      const link = page.getByRole("link", { name: "PermissionRule.ts" });
      await expect.element(link).toBeInTheDocument();
      await expect.element(link).toHaveAttribute("href", filePath);

      await link.click();

      await vi.waitFor(() => {
        expect(openInPreferredEditorMock).toHaveBeenCalledWith(expect.anything(), filePath);
      });
    } finally {
      await screen.unmount();
    }
  });

  it("keeps line anchors working after rewriting file uri hrefs", async () => {
    const filePath =
      "/Users/yashsingh/p/sco/claude-code-extract/src/utils/permissions/PermissionRule.ts";
    const screen = await render(
      <ChatMarkdown text={`[PermissionRule.ts:1](file://${filePath}#L1)`} cwd="/repo/project" />,
    );

    try {
      const link = page.getByRole("link", { name: "PermissionRule.ts:1" });
      await expect.element(link).toBeInTheDocument();
      await expect.element(link).toHaveAttribute("href", `${filePath}#L1`);

      await link.click();

      await vi.waitFor(() => {
        expect(openInPreferredEditorMock).toHaveBeenCalledWith(expect.anything(), `${filePath}:1`);
      });
    } finally {
      await screen.unmount();
    }
  });

  it("falls back to workspace search for repo-local doc links that do not resolve directly", async () => {
    const screen = await render(
      <ChatMarkdown
        text={"[21-ios-dex-first-cutover-](21-ios-dex-first-cutover-)"}
        cwd="/Users/amartyasingh/Documents/projects/dex"
        environmentId={"environment-local" as never}
      />,
    );

    try {
      const link = page.getByRole("link", { name: "21-ios-dex-first-cutover-" });
      await expect.element(link).toBeInTheDocument();

      await link.click();

      await vi.waitFor(() => {
        expect(readEnvironmentApiMock).toHaveBeenCalledWith("environment-local");
        expect(openInPreferredEditorMock).toHaveBeenCalledWith(
          expect.anything(),
          "/Users/amartyasingh/Documents/projects/dex/.plans/21-ios-dex-first-cutover-roadmap.md",
        );
      });
    } finally {
      await screen.unmount();
    }
  });
});
