import { useSession } from "../hooks/useSession";
import DashboardPage from "./DashboardPage";
import SignInPage from "./SignInPage";

function SignOutControl({
  email,
  onSignOut,
}: {
  email: string;
  onSignOut: () => void;
}) {
  return (
    <div className="header-account">
      <a className="header-account-link" href="/account">
        Account settings
      </a>
      <span>{email}</span>
      <button type="button" onClick={onSignOut}>
        Sign out
      </button>
    </div>
  );
}

function AppPage() {
  const { status, user, signOut } = useSession();

  if (status === "loading") {
    return (
      <main className="home-page">
        <span className="brand">PickPic</span>
        <p>Loading…</p>
      </main>
    );
  }

  if (status === "signedOut" || user === null) {
    return <SignInPage />;
  }

  return (
    <DashboardPage
      headerExtra={
        <SignOutControl email={user.email} onSignOut={() => void signOut()} />
      }
    />
  );
}

export default AppPage;
