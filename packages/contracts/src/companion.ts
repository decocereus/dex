import { Schema } from "effect";

import { ServerAuthDescriptor } from "./auth";
import { IsoDateTime, TrimmedNonEmptyString } from "./baseSchemas";
import { ExecutionEnvironmentDescriptor } from "./environment";

export const CompanionPairingTarget = Schema.Struct({
  httpBaseUrl: TrimmedNonEmptyString,
  wsBaseUrl: TrimmedNonEmptyString,
});
export type CompanionPairingTarget = typeof CompanionPairingTarget.Type;

export const CompanionPairingCredential = Schema.Struct({
  id: TrimmedNonEmptyString,
  credential: TrimmedNonEmptyString,
  label: Schema.optionalKey(TrimmedNonEmptyString),
  expiresAt: Schema.DateTimeUtc,
});
export type CompanionPairingCredential = typeof CompanionPairingCredential.Type;

export const CompanionPairingPayload = Schema.Struct({
  version: Schema.Literal(1),
  issuedAt: Schema.DateTimeUtc,
  environment: ExecutionEnvironmentDescriptor,
  auth: ServerAuthDescriptor,
  target: CompanionPairingTarget,
  pairing: CompanionPairingCredential,
});
export type CompanionPairingPayload = typeof CompanionPairingPayload.Type;

export const CreateCompanionPairingPayloadInput = Schema.Struct({
  target: CompanionPairingTarget,
  label: Schema.optionalKey(TrimmedNonEmptyString),
});
export type CreateCompanionPairingPayloadInput = typeof CreateCompanionPairingPayloadInput.Type;

export interface CompanionPairingLinkRecord {
  readonly id: string;
  readonly label?: string;
  readonly issuedAt: IsoDateTime;
  readonly expiresAt: IsoDateTime;
  readonly httpBaseUrl: string;
  readonly wsBaseUrl: string;
}
