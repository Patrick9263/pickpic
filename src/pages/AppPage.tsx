import { useSession } from "../hooks/useSession";
import DashboardPage from "./DashboardPage";
import SignInPage from "./SignInPage";

function SignOutControl({
  email,
  isOperator,
  onSignOut,
}: {
  email: string;
  isOperator: boolean;
  onSignOut: () => void;
}) {
  return (
    <div className="header-account">
      {/*
       * Only shown to an operator, but nothing depends on hiding it: the route
       * refuses a non-operator and the worker refuses the data behind it.
       */}
      {isOperator && (
        <a className="header-account-link" href="/operator">
          Operator
        </a>
      )}
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
  const { status, user, isOperator, signOut, signOutError } = useSession();

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
        <SignOutControl
          email={user.email}
          isOperator={isOperator}
          onSignOut={() => void signOut()}
        />
      }
      signOutError={signOutError}
    />
  );
}

export default AppPage;
