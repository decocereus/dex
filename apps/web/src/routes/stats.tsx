import {
  ActivityIcon,
  BarChart3Icon,
  FolderKanbanIcon,
  Layers3Icon,
  ShieldIcon,
  SparklesIcon,
} from "lucide-react";
import { createFileRoute, redirect } from "@tanstack/react-router";
import { type ReactNode, useMemo } from "react";
import { useShallow } from "zustand/react/shallow";

import { APP_DISPLAY_NAME } from "../branding";
import { isElectron } from "../env";
import {
  useSavedEnvironmentRegistryStore,
  useSavedEnvironmentRuntimeStore,
} from "../environments/runtime";
import { usePrimaryEnvironmentId } from "../environments/primary";
import {
  selectProjectsAcrossEnvironments,
  selectSidebarThreadsAcrossEnvironments,
  useStore,
} from "../store";
import { formatRelativeTimeLabel } from "../timestampFormat";
import { SidebarInset, SidebarTrigger } from "../components/ui/sidebar";

function StatsRouteView() {
  const projects = useStore(useShallow(selectProjectsAcrossEnvironments));
  const threads = useStore(useShallow(selectSidebarThreadsAcrossEnvironments));
  const primaryEnvironmentId = usePrimaryEnvironmentId();
  const savedEnvironmentRegistry = useSavedEnvironmentRegistryStore((state) => state.byId);
  const savedEnvironmentRuntime = useSavedEnvironmentRuntimeStore((state) => state.byId);

  const dashboard = useMemo(() => {
    const activeThreads = threads.filter((thread) => thread.archivedAt === null);
    const archivedThreads = threads.filter((thread) => thread.archivedAt !== null);
    const runningThreads = activeThreads.filter(
      (thread) => thread.latestTurn?.state === "running" || thread.session?.status === "running",
    );
    const pendingApprovalThreads = activeThreads.filter((thread) => thread.hasPendingApprovals);
    const pendingInputThreads = activeThreads.filter((thread) => thread.hasPendingUserInput);
    const worktreeThreads = activeThreads.filter((thread) => thread.worktreePath !== null);

    const providerCounts = activeThreads.reduce<Record<string, number>>((acc, thread) => {
      const provider = thread.session?.provider ?? thread.agentProvider ?? "codex";
      acc[provider] = (acc[provider] ?? 0) + 1;
      return acc;
    }, {});

    const environmentRows = Array.from(
      new Set([
        ...projects.map((project) => project.environmentId),
        ...threads.map((thread) => thread.environmentId),
      ]),
    )
      .map((environmentId) => {
        const runtime = savedEnvironmentRuntime[environmentId];
        const saved = savedEnvironmentRegistry[environmentId];
        const label =
          environmentId === primaryEnvironmentId
            ? (runtime?.descriptor?.label ?? saved?.label ?? "Desktop")
            : (runtime?.descriptor?.label ?? saved?.label ?? environmentId);
        const environmentThreads = activeThreads.filter(
          (thread) => thread.environmentId === environmentId,
        );
        return {
          environmentId,
          label,
          connectionState:
            runtime?.connectionState ??
            (environmentId === primaryEnvironmentId ? "connected" : "disconnected"),
          threadCount: environmentThreads.length,
          runningCount: environmentThreads.filter(
            (thread) =>
              thread.latestTurn?.state === "running" || thread.session?.status === "running",
          ).length,
          pendingCount: environmentThreads.filter(
            (thread) => thread.hasPendingApprovals || thread.hasPendingUserInput,
          ).length,
        };
      })
      .toSorted(
        (left, right) =>
          right.threadCount - left.threadCount || left.label.localeCompare(right.label),
      );

    const recentThreads = activeThreads
      .toSorted((left, right) => {
        const leftTimestamp = Date.parse(
          left.latestUserMessageAt ?? left.updatedAt ?? left.createdAt,
        );
        const rightTimestamp = Date.parse(
          right.latestUserMessageAt ?? right.updatedAt ?? right.createdAt,
        );
        return rightTimestamp - leftTimestamp;
      })
      .slice(0, 6);

    return {
      activeThreads,
      archivedThreads,
      runningThreads,
      pendingApprovalThreads,
      pendingInputThreads,
      worktreeThreads,
      providerCounts,
      environmentRows,
      recentThreads,
    };
  }, [primaryEnvironmentId, projects, savedEnvironmentRegistry, savedEnvironmentRuntime, threads]);

  const providerTotal = Object.values(dashboard.providerCounts).reduce(
    (sum, value) => sum + value,
    0,
  );

  return (
    <SidebarInset className="h-dvh min-h-0 overflow-hidden overscroll-y-none bg-background text-foreground isolate">
      <div className="flex min-h-0 min-w-0 flex-1 flex-col bg-background text-foreground">
        {!isElectron ? (
          <header className="border-b border-border px-3 py-2 sm:px-5">
            <div className="flex items-center gap-2">
              <SidebarTrigger className="size-7 shrink-0 md:hidden" />
              <span className="text-sm font-medium text-foreground">Stats</span>
            </div>
          </header>
        ) : (
          <div className="drag-region flex h-[52px] shrink-0 items-center border-b border-border px-5 wco:h-[env(titlebar-area-height)] wco:pr-[calc(100vw-env(titlebar-area-width)-env(titlebar-area-x)+1em)]">
            <span className="text-xs font-medium tracking-wide text-muted-foreground/70">
              Stats
            </span>
          </div>
        )}

        <div className="min-h-0 flex-1 overflow-y-auto p-5 sm:p-8">
          <div className="mx-auto flex w-full max-w-6xl flex-col gap-6">
            <section className="relative overflow-hidden rounded-[28px] border border-border/70 bg-card px-5 py-5 shadow-sm sm:px-7 sm:py-7">
              <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(40rem_18rem_at_top_right,color-mix(in_srgb,var(--color-blue-500)_14%,transparent),transparent)]" />
              <div className="pointer-events-none absolute inset-y-0 left-0 w-1/2 bg-[linear-gradient(135deg,color-mix(in_srgb,var(--color-emerald-500)_10%,transparent),transparent_55%)]" />
              <div className="relative flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
                <div className="space-y-2">
                  <div className="inline-flex items-center gap-2 rounded-full border border-border/60 bg-background/70 px-3 py-1 text-[11px] font-medium uppercase tracking-[0.14em] text-muted-foreground/70">
                    <SparklesIcon className="size-3.5" />
                    {APP_DISPLAY_NAME}
                  </div>
                  <div>
                    <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">
                      Desktop dashboard
                    </h1>
                    <p className="mt-2 max-w-2xl text-sm leading-relaxed text-muted-foreground">
                      Live operational stats from the current desktop state: projects, threads,
                      environments, active work, and the places where users are getting blocked.
                    </p>
                  </div>
                </div>
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                  <MetricCard
                    icon={Layers3Icon}
                    label="Active threads"
                    value={dashboard.activeThreads.length}
                  />
                  <MetricCard
                    icon={ActivityIcon}
                    label="Running"
                    value={dashboard.runningThreads.length}
                    tone="info"
                  />
                  <MetricCard icon={FolderKanbanIcon} label="Projects" value={projects.length} />
                  <MetricCard
                    icon={ShieldIcon}
                    label="Needs attention"
                    value={
                      dashboard.pendingApprovalThreads.length + dashboard.pendingInputThreads.length
                    }
                    tone="warning"
                  />
                </div>
              </div>
            </section>

            <section className="grid gap-4 lg:grid-cols-[1.5fr_1fr]">
              <Panel
                title="Environment health"
                subtitle="Connection and workload distribution across the desktop’s known environments."
              >
                <div className="space-y-3">
                  {dashboard.environmentRows.map((environment) => (
                    <div
                      key={environment.environmentId}
                      className="flex flex-col gap-3 rounded-2xl border border-border/60 bg-background/60 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
                    >
                      <div className="min-w-0">
                        <div className="flex items-center gap-2">
                          <span
                            className={`inline-flex size-2.5 rounded-full ${
                              environment.connectionState === "connected"
                                ? "bg-success"
                                : environment.connectionState === "connecting"
                                  ? "bg-warning"
                                  : environment.connectionState === "error"
                                    ? "bg-destructive"
                                    : "bg-muted-foreground/40"
                            }`}
                          />
                          <h2 className="truncate text-sm font-medium text-foreground">
                            {environment.label}
                          </h2>
                        </div>
                        <p className="mt-1 text-xs text-muted-foreground">
                          {environment.connectionState} · {environment.threadCount} threads ·{" "}
                          {environment.runningCount} running
                        </p>
                      </div>
                      <div className="flex gap-2 text-[11px] text-muted-foreground">
                        <StatPill label="Pending" value={environment.pendingCount} />
                        <StatPill label="Running" value={environment.runningCount} />
                      </div>
                    </div>
                  ))}
                </div>
              </Panel>

              <Panel
                title="Provider mix"
                subtitle="How active thread load is split across providers right now."
              >
                <div className="space-y-3">
                  {Object.entries(dashboard.providerCounts).length > 0 ? (
                    Object.entries(dashboard.providerCounts)
                      .toSorted((left, right) => right[1] - left[1])
                      .map(([provider, count]) => {
                        const width =
                          providerTotal > 0 ? `${(count / providerTotal) * 100}%` : "0%";
                        return (
                          <div key={provider} className="space-y-1.5">
                            <div className="flex items-center justify-between text-xs">
                              <span className="font-medium text-foreground">
                                {provider === "claudeAgent" ? "Claude" : "Codex"}
                              </span>
                              <span className="text-muted-foreground">{count}</span>
                            </div>
                            <div className="h-2 overflow-hidden rounded-full bg-muted">
                              <div
                                className={`h-full rounded-full ${
                                  provider === "claudeAgent" ? "bg-orange-400" : "bg-primary"
                                }`}
                                style={{ width }}
                              />
                            </div>
                          </div>
                        );
                      })
                  ) : (
                    <p className="text-sm text-muted-foreground">No live thread data yet.</p>
                  )}
                </div>
              </Panel>
            </section>

            <section className="grid gap-4 xl:grid-cols-[1.25fr_1fr]">
              <Panel
                title="Session shape"
                subtitle="A quick read on what the current desktop is doing."
              >
                <div className="grid gap-3 sm:grid-cols-2">
                  <StatTile label="Archived threads" value={dashboard.archivedThreads.length} />
                  <StatTile
                    label="Pending approvals"
                    value={dashboard.pendingApprovalThreads.length}
                    tone="warning"
                  />
                  <StatTile
                    label="Pending user input"
                    value={dashboard.pendingInputThreads.length}
                    tone="warning"
                  />
                  <StatTile
                    label="Worktree threads"
                    value={dashboard.worktreeThreads.length}
                    tone="info"
                  />
                </div>
              </Panel>

              <Panel
                title="Privacy-first telemetry"
                subtitle="Today this dashboard is derived locally from session and environment state."
              >
                <div className="rounded-2xl border border-dashed border-border/70 bg-background/60 px-4 py-4">
                  <p className="text-sm leading-relaxed text-muted-foreground">
                    Anonymous cross-user analytics still needs an explicit opt-in pipeline. The
                    safest next step is aggregated event shipping with no prompts, file paths, IPs,
                    or repository names, plus clear user controls in settings.
                  </p>
                </div>
              </Panel>
            </section>

            <Panel
              title="Recent thread activity"
              subtitle="The most recently touched threads in the current desktop state."
            >
              <div className="space-y-2.5">
                {dashboard.recentThreads.map((thread) => (
                  <div
                    key={`${thread.environmentId}:${thread.id}`}
                    className="flex flex-col gap-2 rounded-2xl border border-border/60 bg-background/60 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div className="min-w-0">
                      <h2 className="truncate text-sm font-medium text-foreground">
                        {thread.title}
                      </h2>
                      <p className="mt-1 text-xs text-muted-foreground">
                        {thread.session?.provider === "claudeAgent" ? "Claude" : "Codex"} ·{" "}
                        {thread.latestTurn?.state === "running"
                          ? "Running"
                          : thread.hasPendingApprovals
                            ? "Pending approval"
                            : thread.hasPendingUserInput
                              ? "Awaiting input"
                              : "Idle"}
                      </p>
                    </div>
                    <div className="text-xs text-muted-foreground">
                      {formatRelativeTimeLabel(
                        thread.latestUserMessageAt ?? thread.updatedAt ?? thread.createdAt,
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </Panel>
          </div>
        </div>
      </div>
    </SidebarInset>
  );
}

function MetricCard({
  icon: Icon,
  label,
  value,
  tone = "default",
}: {
  icon: typeof BarChart3Icon;
  label: string;
  value: number;
  tone?: "default" | "info" | "warning";
}) {
  const toneClassName =
    tone === "info"
      ? "text-blue-600 dark:text-blue-300"
      : tone === "warning"
        ? "text-amber-600 dark:text-amber-300"
        : "text-foreground";

  return (
    <div className="rounded-2xl border border-border/60 bg-background/70 px-3 py-3">
      <div className="flex items-center gap-2 text-xs text-muted-foreground">
        <Icon className="size-3.5" />
        {label}
      </div>
      <div className={`mt-2 text-2xl font-semibold tracking-tight ${toneClassName}`}>{value}</div>
    </div>
  );
}

function Panel({
  title,
  subtitle,
  children,
}: {
  title: string;
  subtitle: string;
  children: ReactNode;
}) {
  return (
    <section className="rounded-[24px] border border-border/70 bg-card p-4 shadow-sm sm:p-5">
      <div className="mb-4">
        <h2 className="text-base font-semibold tracking-tight text-foreground">{title}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{subtitle}</p>
      </div>
      {children}
    </section>
  );
}

function StatTile({
  label,
  value,
  tone = "default",
}: {
  label: string;
  value: number;
  tone?: "default" | "info" | "warning";
}) {
  const toneClassName =
    tone === "info"
      ? "text-blue-600 dark:text-blue-300"
      : tone === "warning"
        ? "text-amber-600 dark:text-amber-300"
        : "text-foreground";

  return (
    <div className="rounded-2xl border border-border/60 bg-background/60 px-4 py-3">
      <div className="text-[11px] uppercase tracking-[0.12em] text-muted-foreground/70">
        {label}
      </div>
      <div className={`mt-2 text-xl font-semibold tracking-tight ${toneClassName}`}>{value}</div>
    </div>
  );
}

function StatPill({ label, value }: { label: string; value: number }) {
  return (
    <span className="inline-flex items-center gap-1 rounded-full border border-border/60 bg-card px-2.5 py-1">
      <span>{label}</span>
      <span className="font-medium text-foreground">{value}</span>
    </span>
  );
}

export const Route = createFileRoute("/stats")({
  beforeLoad: async ({ context }) => {
    if (context.authGateState.status !== "authenticated") {
      throw redirect({ to: "/pair", replace: true });
    }
  },
  component: StatsRouteView,
});
