import { Schema } from "effect";

import { ServerAuthDescriptor } from "./auth";
import { IsoDateTime, TrimmedNonEmptyString } from "./baseSchemas";
import { ExecutionEnvironmentDescriptor } from "./environment";

export const DexDesktopPairingTarget = Schema.Struct({
  httpBaseUrl: TrimmedNonEmptyString,
  wsBaseUrl: TrimmedNonEmptyString,
});
export type DexDesktopPairingTarget = typeof DexDesktopPairingTarget.Type;

export const DexDesktopPairingCredential = Schema.Struct({
  id: TrimmedNonEmptyString,
  credential: TrimmedNonEmptyString,
  label: Schema.optionalKey(TrimmedNonEmptyString),
  expiresAt: Schema.DateTimeUtc,
});
export type DexDesktopPairingCredential = typeof DexDesktopPairingCredential.Type;

export const DexDesktopPairingPayload = Schema.Struct({
  version: Schema.Literal(1),
  issuedAt: Schema.DateTimeUtc,
  environment: ExecutionEnvironmentDescriptor,
  auth: ServerAuthDescriptor,
  target: DexDesktopPairingTarget,
  pairing: DexDesktopPairingCredential,
});
export type DexDesktopPairingPayload = typeof DexDesktopPairingPayload.Type;

export const CreateDexDesktopPairingPayloadInput = Schema.Struct({
  target: DexDesktopPairingTarget,
  label: Schema.optionalKey(TrimmedNonEmptyString),
});
export type CreateDexDesktopPairingPayloadInput = typeof CreateDexDesktopPairingPayloadInput.Type;

export interface DexDesktopPairingLinkRecord {
  readonly id: string;
  readonly label?: string;
  readonly issuedAt: IsoDateTime;
  readonly expiresAt: IsoDateTime;
  readonly httpBaseUrl: string;
  readonly wsBaseUrl: string;
}

export const CompanionPairingTarget = DexDesktopPairingTarget;
export type CompanionPairingTarget = DexDesktopPairingTarget;

export const CompanionPairingCredential = DexDesktopPairingCredential;
export type CompanionPairingCredential = DexDesktopPairingCredential;

export const CompanionPairingPayload = DexDesktopPairingPayload;
export type CompanionPairingPayload = DexDesktopPairingPayload;

export const CreateCompanionPairingPayloadInput = CreateDexDesktopPairingPayloadInput;
export type CreateCompanionPairingPayloadInput = CreateDexDesktopPairingPayloadInput;

export type CompanionPairingLinkRecord = DexDesktopPairingLinkRecord;
