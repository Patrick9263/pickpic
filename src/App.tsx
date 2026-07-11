import "./App.css";

import DashboardPage from "./pages/DashboardPage";
import GalleryPage from "./pages/GalleryPage";

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

      <a className="home-admin-link" href="/admin">
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

  if (/^\/admin\/?$/.test(pathname)) {
    return <DashboardPage />;
  }

  if (pathname === "/") {
    return <HomePage />;
  }

  return <NotFoundPage />;
}

export default App;
