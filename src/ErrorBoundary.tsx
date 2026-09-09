import { Component, type ReactNode } from "react";

interface ErrorBoundaryProps {
  children: ReactNode;
}

interface ErrorBoundaryState {
  hasError: boolean;
}

/*
 * Top-level safety net: without this, any render-time throw (a browser API
 * unexpectedly missing/blocked, a malformed URL, anything not already
 * caught closer to its source) unmounts the whole tree and leaves the
 * visitor — often a non-technical one opening a forwarded link — with a
 * blank white page and nothing to retry.
 */
class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { hasError: false };

  static getDerivedStateFromError(): ErrorBoundaryState {
    return { hasError: true };
  }

  render() {
    if (this.state.hasError) {
      return (
        <main className="home-page">
          <span className="brand">PickPic</span>
          <h1>Something went wrong</h1>
          <p>
            Try reloading the page. If it keeps happening, let the photographer
            know.
          </p>
        </main>
      );
    }

    return this.props.children;
  }
}

export default ErrorBoundary;
