import {
  type AuthBearerBootstrapResult,
  AuthBootstrapInput,
  AuthCreatePairingCredentialInput,
  AuthRevokeClientSessionInput,
  AuthRevokePairingLinkInput,
  type AuthWebSocketTokenResult,
  CompanionPairingPayload,
  CreateCompanionPairingPayloadInput,
} from "@dex/contracts";
import { DateTime, Effect, Option, Schema } from "effect";
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/unstable/http";

import { AuthError, ServerAuth } from "./Services/ServerAuth.ts";
import { SessionCredentialService } from "./Services/SessionCredentialService.ts";
import { deriveAuthClientMetadata } from "./utils.ts";
import { ServerEnvironment } from "../environment/Services/ServerEnvironment.ts";

export const respondToAuthError = (error: AuthError) =>
  Effect.gen(function* () {
    if ((error.status ?? 500) >= 500) {
      yield* Effect.logError("auth route failed", {
        message: error.message,
        cause: error.cause,
      });
    }
    return HttpServerResponse.jsonUnsafe(
      {
        error: error.message,
      },
      { status: error.status ?? 500 },
    );
  });

export const authSessionRouteLayer = HttpRouter.add(
  "GET",
  "/api/auth/session",
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest;
    const serverAuth = yield* ServerAuth;
    const session = yield* serverAuth.getSessionState(request);
    return HttpServerResponse.jsonUnsafe(session, { status: 200 });
  }),
);

const PairingCredentialRequestHeaders = Schema.Struct({
  "content-length": Schema.optionalKey(Schema.String),
  "content-type": Schema.optionalKey(Schema.String),
  "transfer-encoding": Schema.optionalKey(Schema.String),
});

function hasRequestBody(headers: typeof PairingCredentialRequestHeaders.Type) {
  const contentLengthHeader = headers["content-length"];
  if (typeof contentLengthHeader === "string") {
    const contentLength = Number.parseInt(contentLengthHeader, 10);
    if (Number.isFinite(contentLength)) {
      return contentLength > 0;
    }
  }
  return typeof headers["transfer-encoding"] === "string";
}

const AUTHORIZATION_PREFIX = "Bearer ";
const DEFAULT_COMPANION_WEB_PATH = "/_chat/";

function parseAuthenticatedRequestCredential(
  request: HttpServerRequest.HttpServerRequest,
  cookieName: string,
) {
  const cookieToken = request.cookies[cookieName];
  if (typeof cookieToken === "string" && cookieToken.length > 0) {
    return cookieToken;
  }
  const authorization = request.headers["authorization"];
  if (typeof authorization === "string" && authorization.startsWith(AUTHORIZATION_PREFIX)) {
    const token = authorization.slice(AUTHORIZATION_PREFIX.length).trim();
    if (token.length > 0) {
      return token;
    }
  }
  return null;
}

function normalizeCompanionWebPath(path: string | null | undefined) {
  if (!path) {
    return DEFAULT_COMPANION_WEB_PATH;
  }
  const trimmed = path.trim();
  if (!trimmed.startsWith("/") || trimmed.startsWith("//")) {
    return DEFAULT_COMPANION_WEB_PATH;
  }
  return trimmed;
}

export const authBootstrapRouteLayer = HttpRouter.add(
  "POST",
  "/api/auth/bootstrap",
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest;
    const serverAuth = yield* ServerAuth;
    const sessions = yield* SessionCredentialService;
    const payload = yield* HttpServerRequest.schemaBodyJson(AuthBootstrapInput).pipe(
      Effect.mapError(
        (cause) =>
          new AuthError({
            message: "Invalid bootstrap payload.",
            status: 400,
            cause,
          }),
      ),
    );
    const result = yield* serverAuth.exchangeBootstrapCredential(
      payload.credential,
      deriveAuthClientMetadata({ request }),
    );

    return yield* HttpServerResponse.jsonUnsafe(result.response, { status: 200 }).pipe(
      HttpServerResponse.setCookie(sessions.cookieName, result.sessionToken, {
        expires: DateTime.toDate(result.response.expiresAt),
        httpOnly: true,
        path: "/",
        sameSite: "lax",
      }),
    );
  }).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error))),
);

export const authBearerBootstrapRouteLayer = HttpRouter.add(
  "POST",
  "/api/auth/bootstrap/bearer",
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest;
    const serverAuth = yield* ServerAuth;
    const payload = yield* HttpServerRequest.schemaBodyJson(AuthBootstrapInput).pipe(
      Effect.mapError(
        (cause) =>
          new AuthError({
            message: "Invalid bootstrap payload.",
            status: 400,
            cause,
          }),
      ),
    );
    const result = yield* serverAuth.exchangeBootstrapCredentialForBearerSession(
      payload.credential,
      deriveAuthClientMetadata({ request }),
    );
    return HttpServerResponse.jsonUnsafe(result satisfies AuthBearerBootstrapResult, {
      status: 200,
    });
  }).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error))),
);

export const authWebSocketTokenRouteLayer = HttpRouter.add(
  "POST",
  "/api/auth/ws-token",
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest;
    const serverAuth = yield* ServerAuth;
    const session = yield* serverAuth.authenticateHttpRequest(request);
    const result = yield* serverAuth.issueWebSocketToken(session);
    return HttpServerResponse.jsonUnsafe(result satisfies AuthWebSocketTokenResult, {
      status: 200,
    });
  }).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error))),
);

export const authPairingCredentialRouteLayer = HttpRouter.add(
  "POST",
  "/api/auth/pairing-token",
  Effect.gen(function* () {
    const serverAuth = yield* ServerAuth;
    const request = yield* HttpServerRequest.HttpServerRequest;
    const session = yield* serverAuth.authenticateHttpRequest(request);
    if (session.role !== "owner") {
      return yield* new AuthError({
        message: "Only owner sessions can create pairing credentials.",
        status: 403,
      });
    }
    const headers = yield* HttpServerRequest.schemaHeaders(PairingCredentialRequestHeaders).pipe(
      Effect.mapError(
        (cause) =>
          new AuthError({
            message: "Invalid pairing credential request headers.",
            status: 400,
            cause,
          }),
      ),
    );
    const payload = hasRequestBody(headers)
      ? yield* HttpServerRequest.schemaBodyJson(AuthCreatePairingCredentialInput).pipe(
          Effect.mapError(
            (cause) =>
              new AuthError({
                message: "Invalid pairing credential payload.",
                status: 400,
                cause,
              }),
          ),
        )
      : {};
    const result = yield* serverAuth.issuePairingCredential(payload);
    return HttpServerResponse.jsonUnsafe(result, { status: 200 });
  }).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error))),
);

const authCompanionPairingPayloadHandler = Effect.gen(function* () {
  const { serverAuth } = yield* authenticateOwnerSession;
  const serverEnvironment = yield* ServerEnvironment;
  const payload = yield* HttpServerRequest.schemaBodyJson(CreateCompanionPairingPayloadInput).pipe(
    Effect.mapError(
      (cause) =>
        new AuthError({
          message: "Invalid companion pairing payload request.",
          status: 400,
          cause,
        }),
    ),
  );
  const [descriptor, authDescriptor, pairing] = yield* Effect.all([
    serverEnvironment.getDescriptor,
    serverAuth.getDescriptor(),
    serverAuth.issuePairingCredential(payload.label ? { label: payload.label } : {}),
  ]);
  return HttpServerResponse.jsonUnsafe(
    {
      version: 1,
      issuedAt: DateTime.fromDateUnsafe(new Date()),
      environment: descriptor,
      auth: authDescriptor,
      target: payload.target,
      pairing,
    } satisfies CompanionPairingPayload,
    { status: 200 },
  );
}).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error)));

export const authCompanionPairingPayloadRouteLayer = HttpRouter.add(
  "POST",
  "/api/auth/companion/pairing",
  authCompanionPairingPayloadHandler,
);

export const authMobilePairingPayloadRouteLayer = HttpRouter.add(
  "POST",
  "/api/auth/mobile/pairing",
  authCompanionPairingPayloadHandler,
);

const authCompanionWebSessionHandler = Effect.gen(function* () {
  const request = yield* HttpServerRequest.HttpServerRequest;
  const serverAuth = yield* ServerAuth;
  const sessions = yield* SessionCredentialService;
  const session = yield* serverAuth.authenticateHttpRequest(request);
  const credential = parseAuthenticatedRequestCredential(request, sessions.cookieName);
  if (!credential) {
    return yield* new AuthError({
      message: "Authentication required.",
      status: 401,
    });
  }
  const requestUrl = HttpServerRequest.toURL(request);
  const nextPath = normalizeCompanionWebPath(
    Option.isSome(requestUrl) ? requestUrl.value.searchParams.get("path") : null,
  );
  return yield* HttpServerResponse.redirect(nextPath, { status: 302 }).pipe(
    HttpServerResponse.setCookie(sessions.cookieName, credential, {
      ...(session.expiresAt ? { expires: DateTime.toDate(session.expiresAt) } : {}),
      httpOnly: true,
      path: "/",
      sameSite: "lax",
    }),
  );
}).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error)));

export const authCompanionWebSessionRouteLayer = HttpRouter.add(
  "GET",
  "/api/auth/companion/web-session",
  authCompanionWebSessionHandler,
);

export const authMobileWebSessionRouteLayer = HttpRouter.add(
  "GET",
  "/api/auth/mobile/web-session",
  authCompanionWebSessionHandler,
);

const authenticateOwnerSession = Effect.gen(function* () {
  const request = yield* HttpServerRequest.HttpServerRequest;
  const serverAuth = yield* ServerAuth;
  const session = yield* serverAuth.authenticateHttpRequest(request);
  if (session.role !== "owner") {
    return yield* new AuthError({
      message: "Only owner sessions can manage network access.",
      status: 403,
    });
  }
  return { serverAuth, session } as const;
});

export const authPairingLinksRouteLayer = HttpRouter.add(
  "GET",
  "/api/auth/pairing-links",
  Effect.gen(function* () {
    const { serverAuth } = yield* authenticateOwnerSession;
    const pairingLinks = yield* serverAuth.listPairingLinks();
    return HttpServerResponse.jsonUnsafe(pairingLinks, { status: 200 });
  }).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error))),
);

export const authPairingLinksRevokeRouteLayer = HttpRouter.add(
  "POST",
  "/api/auth/pairing-links/revoke",
  Effect.gen(function* () {
    const { serverAuth } = yield* authenticateOwnerSession;
    const payload = yield* HttpServerRequest.schemaBodyJson(AuthRevokePairingLinkInput).pipe(
      Effect.mapError(
        (cause) =>
          new AuthError({
            message: "Invalid revoke pairing link payload.",
            status: 400,
            cause,
          }),
      ),
    );
    const revoked = yield* serverAuth.revokePairingLink(payload.id);
    return HttpServerResponse.jsonUnsafe({ revoked }, { status: 200 });
  }).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error))),
);

export const authClientsRouteLayer = HttpRouter.add(
  "GET",
  "/api/auth/clients",
  Effect.gen(function* () {
    const { serverAuth, session } = yield* authenticateOwnerSession;
    const clients = yield* serverAuth.listClientSessions(session.sessionId);
    return HttpServerResponse.jsonUnsafe(clients, { status: 200 });
  }).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error))),
);

export const authClientsRevokeRouteLayer = HttpRouter.add(
  "POST",
  "/api/auth/clients/revoke",
  Effect.gen(function* () {
    const { serverAuth, session } = yield* authenticateOwnerSession;
    const payload = yield* HttpServerRequest.schemaBodyJson(AuthRevokeClientSessionInput).pipe(
      Effect.mapError(
        (cause) =>
          new AuthError({
            message: "Invalid revoke client payload.",
            status: 400,
            cause,
          }),
      ),
    );
    const revoked = yield* serverAuth.revokeClientSession(session.sessionId, payload.sessionId);
    return HttpServerResponse.jsonUnsafe({ revoked }, { status: 200 });
  }).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error))),
);

export const authClientsRevokeOthersRouteLayer = HttpRouter.add(
  "POST",
  "/api/auth/clients/revoke-others",
  Effect.gen(function* () {
    const { serverAuth, session } = yield* authenticateOwnerSession;
    const revokedCount = yield* serverAuth.revokeOtherClientSessions(session.sessionId);
    return HttpServerResponse.jsonUnsafe({ revokedCount }, { status: 200 });
  }).pipe(Effect.catchTag("AuthError", (error) => respondToAuthError(error))),
);
