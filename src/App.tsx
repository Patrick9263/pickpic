import "./App.css";

import AccountSettingsPage from "./pages/AccountSettingsPage";
import AppPage from "./pages/AppPage";
import DashboardPage from "./pages/DashboardPage";
import GalleryPage from "./pages/GalleryPage";
import SignInPage from "./pages/SignInPage";
import SignUpPage from "./pages/SignUpPage";

const ADMIN_APP_ORIGIN = (
  import.meta.env.VITE_ADMIN_APP_ORIGIN || window.location.origin
).replace(/\/+$/, "");

// No window.location.origin fallback here, unlike the origin vars above: this
// value only comes from .env.production, so on a bare `npm run dev` it must
// stay unset rather than making every localhost path match the app shell.
const APP_ORIGIN = import.meta.env.VITE_APP_ORIGIN || null;

function HomePage() {
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
    return <GalleryPage shareToken={decodeURIComponent(galleryMatch[1])} />;
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
