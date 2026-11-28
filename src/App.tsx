import "./App.css";

import { useState } from "react";

import { safeDecodeShareToken } from "./appHelpers";
import AccountSettingsPage from "./pages/AccountSettingsPage";
import AppPage from "./pages/AppPage";
import DashboardPage from "./pages/DashboardPage";
import GalleryPage from "./pages/GalleryPage";
import {
  readRecentGalleries,
  removeRecentGallery,
  writeRecentGalleries,
} from "./pages/galleryHelpers";
import OperatorPage from "./pages/OperatorPage";
import RawConfirmPage from "./pages/RawConfirmPage";
import SignInPage from "./pages/SignInPage";
import SignUpPage from "./pages/SignUpPage";

const ADMIN_APP_ORIGIN = (
  import.meta.env.VITE_ADMIN_APP_ORIGIN || window.location.origin
).replace(/\/+$/, "");

// No window.location.origin fallback here, unlike the origin vars above: this
// value only comes from .env.production, so on a bare `npm run dev` it must
// stay unset rather than making every localhost path match the app shell.
const APP_ORIGIN = import.meta.env.VITE_APP_ORIGIN || null;

function formatOpenedDate(timestamp: string): string {
  const date = new Date(timestamp);

  return Number.isNaN(date.getTime())
    ? ""
    : date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function HomePage() {
  // Read once on mount: nothing else writes the list while this page is open,
  // and the home page must not fetch anything to validate it (#407).
  const [recentGalleries, setRecentGalleries] = useState(() =>
    readRecentGalleries(() => window.localStorage),
  );

  function handleRemove(shareToken: string): void {
    const remaining = removeRecentGallery(recentGalleries, shareToken);

    setRecentGalleries(remaining);
    writeRecentGalleries(() => window.localStorage, remaining);
  }

  return (
    <main className="home-page">
      <span className="brand">PickPic</span>

      <h1>
        Private photo galleries made for picking the photos worth editing.
      </h1>

      <p>
        Open a shared gallery link to view photos, request edits, and leave
        comments.
      </p>

      {recentGalleries.length > 0 ? (
        <section className="recent-galleries" aria-labelledby="recent-heading">
          <h2 id="recent-heading">Recently opened on this device</h2>

          <ul>
            {recentGalleries.map((gallery) => {
              const openedDate = formatOpenedDate(gallery.lastOpenedAt);

              return (
                <li className="recent-gallery" key={gallery.shareToken}>
                  <a
                    className="recent-gallery-link"
                    href={`/g/${encodeURIComponent(gallery.shareToken)}`}
                  >
                    <span className="recent-gallery-title">
                      {gallery.title}
                    </span>
                    {openedDate ? (
                      <span className="recent-gallery-meta">
                        Opened {openedDate}
                      </span>
                    ) : null}
                  </a>

                  <button
                    aria-label={`Remove ${gallery.title} from this list`}
                    className="secondary-button recent-gallery-remove"
                    onClick={() => handleRemove(gallery.shareToken)}
                    type="button"
                  >
                    Remove
                  </button>
                </li>
              );
            })}
          </ul>
        </section>
      ) : null}

      <a className="home-admin-link" href={`${ADMIN_APP_ORIGIN}/admin`}>
        Photographer dashboard
      </a>
    </main>
  );
}

function NotFoundPage() {
  return (
    <main className="home-page">
      <span className="brand">PickPic</span>
      <h1>Page not found</h1>
      <a className="home-admin-link" href="/">
        Return home
      </a>
    </main>
  );
}

function App() {
  const pathname = window.location.pathname;

  const galleryMatch = pathname.match(/^\/g\/([^/]+)\/?$/);

  if (galleryMatch) {
    return <GalleryPage shareToken={safeDecodeShareToken(galleryMatch[1])} />;
  }

  const rawConfirmMatch = pathname.match(/^\/g\/([^/]+)\/raw-confirm\/?$/);

  if (rawConfirmMatch) {
    return (
      <RawConfirmPage shareToken={safeDecodeShareToken(rawConfirmMatch[1])} />
    );
  }

  if (/^\/sign-in\/?$/.test(pathname)) {
    return <SignInPage />;
  }

  if (/^\/sign-up\/?$/.test(pathname)) {
    return <SignUpPage />;
  }

  if (/^\/admin\/?$/.test(pathname)) {
    return <DashboardPage />;
  }

  /*
   * Not gated on APP_ORIGIN the way /account is, and not linked from anywhere.
   *
   * Ungated because the console is useful from either authenticated origin --
   * app.pickpic.photos under a session, admin.pickpic.photos under Access --
   * and the page renders nothing either way unless /api/operator/accounts
   * answers, which is the real gate. Unlinked because the alternative is
   * teaching the session endpoint to report an operator flag, which would cost
   * every sign-in an extra query to answer a question that is true for one
   * person.
   */
  if (/^\/operator\/?$/.test(pathname)) {
    return <OperatorPage />;
  }

  if (window.location.origin === APP_ORIGIN && pathname === "/") {
    return <AppPage />;
  }

  if (
    window.location.origin === APP_ORIGIN &&
    /^\/account\/?$/.test(pathname)
  ) {
    return <AccountSettingsPage />;
  }

  if (pathname === "/") {
    return <HomePage />;
  }

  return <NotFoundPage />;
}

export default App;
