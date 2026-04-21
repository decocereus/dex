import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";

let sidebarSide: "left" | "right" = "left";

vi.mock("@tanstack/react-router", () => ({
  useNavigate: () => vi.fn(),
}));

vi.mock("./Sidebar", () => ({
  default: () => <div data-testid="thread-sidebar-content">Threads</div>,
}));

vi.mock("../hooks/useSettings", () => ({
  useSettings: (selector?: (settings: { sidebarSide: "left" | "right" }) => unknown) => {
    const settings = { sidebarSide };
    return selector ? selector(settings) : settings;
  },
}));

import { AppSidebarLayout } from "./AppSidebarLayout";

describe("AppSidebarLayout", () => {
  it("renders the main sidebar before content when placement is left", () => {
    sidebarSide = "left";

    const html = renderToStaticMarkup(
      <AppSidebarLayout>
        <div data-testid="content">Content</div>
      </AppSidebarLayout>,
    );

    expect(html).toContain('data-side="left"');
    expect(html).toContain("border-r");
    expect(html.indexOf('data-slot="sidebar"')).toBeLessThan(html.indexOf('data-testid="content"'));
  });

  it("renders the main sidebar after content when placement is right", () => {
    sidebarSide = "right";

    const html = renderToStaticMarkup(
      <AppSidebarLayout>
        <div data-testid="content">Content</div>
      </AppSidebarLayout>,
    );

    expect(html).toContain('data-side="right"');
    expect(html).toContain("border-l");
    expect(html.indexOf('data-slot="sidebar"')).toBeGreaterThan(
      html.indexOf('data-testid="content"'),
    );
  });
});
