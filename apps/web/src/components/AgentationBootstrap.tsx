import { Component, type ReactNode, Suspense, lazy, useMemo } from "react";

import { isElectron } from "../env";

const LazyAgentation = lazy(async () => {
  const module = await import("agentation");
  return { default: module.Agentation };
});

const AGENTATION_STORAGE_KEY = "dex.agentation.enabled";

type AgentationErrorBoundaryProps = {
  children: ReactNode;
};

type AgentationErrorBoundaryState = {
  hasError: boolean;
};

class AgentationErrorBoundary extends Component<
  AgentationErrorBoundaryProps,
  AgentationErrorBoundaryState
> {
  override state: AgentationErrorBoundaryState = {
    hasError: false,
  };

  static getDerivedStateFromError(): AgentationErrorBoundaryState {
    return {
      hasError: true,
    };
  }

  override componentDidCatch(error: unknown) {
    console.error("[agentation] disabled after runtime error", error);
  }

  override render() {
    if (this.state.hasError) {
      return null;
    }

    return this.props.children;
  }
}

function readAgentationEnabled(): boolean {
  if (typeof window === "undefined") {
    return false;
  }

  try {
    const url = new URL(window.location.href);
    const forceEnabled = url.searchParams.get("agentation");
    if (forceEnabled === "1" || forceEnabled === "true") {
      return true;
    }

    return window.localStorage.getItem(AGENTATION_STORAGE_KEY) === "true";
  } catch {
    return false;
  }
}

export function AgentationBootstrap() {
  // Keep Agentation opt-in until the React 19/Electron integration is stable.
  const enabled = useMemo(() => readAgentationEnabled(), []);

  if (!isElectron || !enabled) {
    return null;
  }

  return (
    <AgentationErrorBoundary>
      <Suspense fallback={null}>
        <LazyAgentation />
      </Suspense>
    </AgentationErrorBoundary>
  );
}
