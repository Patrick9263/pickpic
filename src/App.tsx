import "./App.css";
import GalleryPage from "./pages/GalleryPage";
import DashboardPage from "./pages/DashboardPage";

function App() {
  const galleryMatch = window.location.pathname.match(/^\/g\/([^/]+)\/?$/);

  if (galleryMatch) {
    return <GalleryPage shareToken={decodeURIComponent(galleryMatch[1])} />;
  }

  return <DashboardPage />;
}

export default App;
