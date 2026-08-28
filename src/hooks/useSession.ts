import { useCallback, useEffect, useState } from "react";
import { fetchJson } from "../api";
import type { SessionAccount, SessionResponse, SessionUser } from "../types";

type SessionStatus = "loading" | "signedIn" | "signedOut";

interface UseSessionResult {
  status: SessionStatus;
  account: SessionAccount | null;
  user: SessionUser | null;
  refresh: () => void;
  signOut: () => Promise<void>;
}

export function useSession(): UseSessionResult {
  const [status, setStatus] = useState<SessionStatus>("loading");
  const [account, setAccount] = useState<SessionAccount | null>(null);
  const [user, setUser] = useState<SessionUser | null>(null);
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
        setStatus("signedIn");
      })
      .catch(() => {
        if (cancelled) {
          return;
        }

        setAccount(null);
        setUser(null);
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
    await fetchJson("/api/auth/session", { method: "DELETE" });
    setAccount(null);
    setUser(null);
    setStatus("signedOut");
  }, []);

  return { status, account, user, refresh, signOut };
}
