import { useEffect } from "react";
import {
  DEFAULT_INTERFACE_FONT_FAMILY,
  DEFAULT_MONO_FONT_FAMILY,
  type InterfaceFontFamily,
  type MonoFontFamily,
} from "@dex/contracts/settings";

import { useSettings } from "./useSettings";

function applyTypographyPreferences(input: {
  interfaceFontFamily: InterfaceFontFamily;
  monoFontFamily: MonoFontFamily;
}) {
  const root = document.documentElement;
  root.dataset.interfaceFont = input.interfaceFontFamily;
  root.dataset.monoFont = input.monoFontFamily;
}

export function TypographyBootstrap() {
  const interfaceFontFamily = useSettings((settings) => settings.interfaceFontFamily);
  const monoFontFamily = useSettings((settings) => settings.monoFontFamily);

  useEffect(() => {
    applyTypographyPreferences({
      interfaceFontFamily,
      monoFontFamily,
    });
  }, [interfaceFontFamily, monoFontFamily]);

  return null;
}

if (typeof document !== "undefined") {
  applyTypographyPreferences({
    interfaceFontFamily: DEFAULT_INTERFACE_FONT_FAMILY,
    monoFontFamily: DEFAULT_MONO_FONT_FAMILY,
  });
}
