import { useCallback, useEffect, useState } from "react";
import { fetchJson } from "../api";
import type { SessionAccount, SessionResponse, SessionUser } from "../types";

type SessionStatus = "loading" | "signedIn" | "signedOut";

interface UseSessionResult {
  status: SessionStatus;
  account: SessionAccount | null;
  user: SessionUser | null;

  /*
   * Defaults to false and is cleared on sign-out, so a nav link is never shown
   * on a stale flag. It only decides whether the link is drawn — the worker
   * checks the real thing on every operator request.
   */
  isOperator: boolean;

  signOutError: string | null;
  refresh: () => void;
  signOut: () => Promise<void>;
}

export function useSession(): UseSessionResult {
  const [status, setStatus] = useState<SessionStatus>("loading");
  const [account, setAccount] = useState<SessionAccount | null>(null);
  const [user, setUser] = useState<SessionUser | null>(null);
  const [isOperator, setIsOperator] = useState(false);
  const [signOutError, setSignOutError] = useState<string | null>(null);
  const [refreshToken, setRefreshToken] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setStatus("loading");

    fetchJson<SessionResponse>("/api/auth/session")
      .then((response) => {
        if (cancelled) {
          return;
        }

        setAccount(response.account);
        setUser(response.user);
        setIsOperator(response.isOperator === true);
        setStatus("signedIn");
      })
      .catch(() => {
        if (cancelled) {
          return;
        }

        setAccount(null);
        setUser(null);
        setIsOperator(false);
        setStatus("signedOut");
      });

    return () => {
      cancelled = true;
    };
  }, [refreshToken]);

  const refresh = useCallback(() => {
    setRefreshToken((currentValue) => currentValue + 1);
  }, []);

  const signOut = useCallback(async () => {
    try {
      await fetchJson("/api/auth/session", { method: "DELETE" });
    } catch (caughtError) {
      // Clear local state even on failure, since the cookie is __Host- scoped
      // and a reload will re-check it. Surface the error so the user knows
      // something went wrong.
      setSignOutError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to sign out.",
      );
    } finally {
      // Always clear local state on sign-out attempt. The __Host- cookie
      // cannot be cleared client-side, so a reload will re-validate the
      // session state with the server.
      setAccount(null);
      setUser(null);
      setIsOperator(false);
      setStatus("signedOut");
    }
  }, []);

  return {
    status,
    account,
    user,
    isOperator,
    signOutError,
    refresh,
    signOut,
  };
}
