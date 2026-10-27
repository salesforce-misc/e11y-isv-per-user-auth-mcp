import { LightningElement } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getSetupStatus from "@salesforce/apex/GitHubMcpSetupController.getSetupStatus";
import saveClientCredentials from "@salesforce/apex/GitHubMcpSetupController.saveClientCredentials";
import getAuthenticationUrl from "@salesforce/apex/GitHubMcpSetupController.getAuthenticationUrl";
import disconnect from "@salesforce/apex/GitHubMcpSetupController.disconnect";

const STEP_LABELS = {
  permissions: "Permissions",
  oauthApp: "Create a GitHub OAuth App",
  credentials: "Client credentials",
  authenticate: "Connect your GitHub account",
  next: "Next steps"
};

// Steps the page can check. "Next steps" happen elsewhere in Setup.
const TRACKED_STEP_COUNT = 4;

const GITHUB_NEW_OAUTH_APP_URL = "https://github.com/settings/applications/new";

// The Registry's page for a single server needs the External Service
// Registration Id, which only the Tooling API returns, so link to the
// Registry itself.
const AGENTFORCE_REGISTRY_URL = "/lightning/setup/AgentforceRegistry/home";

function reduceError(error) {
  return error?.body?.message || error?.message || "Unknown error";
}

export default class GithubMcpSetup extends LightningElement {
  labels = STEP_LABELS;
  githubNewAppUrl = GITHUB_NEW_OAUTH_APP_URL;
  registryUrl = AGENTFORCE_REGISTRY_URL;

  status;
  error;
  isLoading = false;
  isSaving = false;
  isConnecting = false;
  clientId = "";
  clientSecret = "";

  // Completed sections collapse; these reopen them.
  isReplacingCredentials = false;
  oauthInstructionsExpanded = false;

  // Set while the GitHub sign-in tab is open, so the status refreshes
  // when the admin comes back to this tab.
  awaitingAuthentication = false;

  connectedCallback() {
    document.addEventListener("visibilitychange", this.handleVisibilityChange);
    this.loadStatus();
  }

  disconnectedCallback() {
    document.removeEventListener(
      "visibilitychange",
      this.handleVisibilityChange
    );
  }

  async loadStatus() {
    this.isLoading = true;
    try {
      const status = await getSetupStatus();
      if (!this.status) {
        this.clientId = status.clientId || "";
      }
      this.status = status;
      this.error = undefined;
    } catch (error) {
      this.error = reduceError(error);
    } finally {
      this.isLoading = false;
    }
  }

  get hasPermissions() {
    return Boolean(
      this.status?.hasPrincipalAccess && this.status?.hasUecAccess
    );
  }

  get needsPermissions() {
    return Boolean(this.status) && !this.hasPermissions;
  }

  get hasCredentials() {
    return Boolean(
      this.status?.clientId && this.status?.clientSecretConfigured
    );
  }

  get isConnected() {
    return this.status?.authenticationStatus === "Configured";
  }

  /** The first step that isn't done yet. */
  get currentStep() {
    if (!this.hasPermissions) {
      return "permissions";
    }
    if (!this.hasCredentials) {
      return "oauthApp";
    }
    return this.isConnected ? "next" : "authenticate";
  }

  stepState(step, isDone) {
    if (isDone) {
      return "complete";
    }
    return step === this.currentStep ? "current" : "upcoming";
  }

  get permissionsState() {
    return this.stepState("permissions", this.hasPermissions);
  }

  // GitHub can't be asked whether the app exists, so saved credentials
  // are taken to mean it does.
  get oauthAppState() {
    return this.stepState("oauthApp", this.hasCredentials);
  }

  get credentialsState() {
    return this.stepState("credentials", this.hasCredentials);
  }

  get authenticateState() {
    return this.stepState("authenticate", this.isConnected);
  }

  get nextStepsState() {
    return this.stepState("next", false);
  }

  get progressSummary() {
    const done = [
      this.hasPermissions,
      this.hasCredentials,
      this.hasCredentials,
      this.isConnected
    ].filter(Boolean).length;
    if (done === TRACKED_STEP_COUNT) {
      return "Setup is done. Finish with the next steps below.";
    }
    return `${done} of ${TRACKED_STEP_COUNT} setup steps done. Next: ${
      STEP_LABELS[this.currentStep]
    }.`;
  }

  get permissionChecks() {
    return [
      {
        key: "principal",
        label: "Access to the GitHub external credential's per-user principal",
        ok: this.status?.hasPrincipalAccess
      },
      {
        key: "uec",
        label: "Read access to User External Credentials",
        ok: this.status?.hasUecAccess
      }
    ].map((check) => ({
      ...check,
      iconName: check.ok ? "utility:success" : "utility:warning",
      iconVariant: check.ok ? "success" : "warning",
      iconText: check.ok ? "Granted" : "Missing"
    }));
  }

  get permissionSetUrl() {
    const id = this.status?.userPermSetId;
    return id
      ? `/lightning/setup/PermSets/page?address=${encodeURIComponent("/" + id)}`
      : undefined;
  }

  get showOauthInstructions() {
    return !this.hasCredentials || this.oauthInstructionsExpanded;
  }

  get oauthInstructionsToggleLabel() {
    return this.oauthInstructionsExpanded
      ? "Hide instructions"
      : "Show instructions";
  }

  get showCredentialsForm() {
    return !this.hasCredentials || this.isReplacingCredentials;
  }

  get credentialsSummary() {
    return `Client ID ${this.status?.clientId}. The client secret is saved and can't be viewed.`;
  }

  get saveLabel() {
    return this.isReplacingCredentials
      ? "Replace credentials"
      : "Save credentials";
  }

  get saveDisabled() {
    return this.isSaving || !this.clientId.trim() || !this.clientSecret.trim();
  }

  get connectLabel() {
    return this.isConnected ? "Reconnect GitHub" : "Connect GitHub";
  }

  // Once connected, reconnecting is a secondary action.
  get connectVariant() {
    return this.isConnected ? "neutral" : "brand";
  }

  get connectDisabled() {
    return this.isConnecting || !this.hasPermissions || !this.hasCredentials;
  }

  get connectHelp() {
    if (!this.hasPermissions) {
      return "Finish step 1 first.";
    }
    if (!this.hasCredentials) {
      return "Save the client credentials in step 3 first.";
    }
    if (this.isConnected) {
      return "Your GitHub account is connected. Reconnect if you switch GitHub accounts or OAuth Apps.";
    }
    return "GitHub opens in a new tab. When you're done, come back to this tab and the status updates.";
  }

  handleRefresh() {
    this.loadStatus();
  }

  // An arrow function so the same reference can be added and removed as a
  // document listener.
  handleVisibilityChange = () => {
    if (document.visibilityState === "visible" && this.awaitingAuthentication) {
      this.awaitingAuthentication = false;
      this.loadStatus();
    }
  };

  handleToggleOauthInstructions() {
    this.oauthInstructionsExpanded = !this.oauthInstructionsExpanded;
  }

  async handleCopyCallback() {
    try {
      await navigator.clipboard.writeText(this.status.callbackUrl);
      this.toast("success", "Callback URL copied.");
    } catch {
      this.toast("warning", "Couldn't copy. Select the URL and copy it.");
    }
  }

  handleStartReplace() {
    this.clientId = this.status?.clientId || "";
    this.isReplacingCredentials = true;
  }

  handleCancelReplace() {
    this.clientSecret = "";
    this.isReplacingCredentials = false;
  }

  handleClientIdChange(event) {
    this.clientId = event.detail.value || "";
  }

  handleClientSecretChange(event) {
    this.clientSecret = event.detail.value || "";
  }

  async handleSave() {
    this.isSaving = true;
    try {
      this.status = await saveClientCredentials({
        clientId: this.clientId,
        clientSecret: this.clientSecret
      });
      this.clientId = this.status.clientId || "";
      this.isReplacingCredentials = false;
      this.toast("success", "Client credentials saved.");
    } catch (error) {
      this.toast("error", reduceError(error));
    } finally {
      // Never keep the secret around once it has been sent.
      this.clientSecret = "";
      this.isSaving = false;
    }
  }

  async handleConnect() {
    // Open the tab inside the click handler so the browser doesn't block
    // it, then point it at GitHub once the URL comes back.
    const authWindow = window.open("", "_blank");
    this.isConnecting = true;
    try {
      const url = await getAuthenticationUrl();
      if (authWindow) {
        authWindow.location.href = url;
        this.awaitingAuthentication = true;
      } else {
        this.toast("warning", "Allow pop-ups for this site, then try again.");
      }
    } catch (error) {
      authWindow?.close();
      this.toast("error", reduceError(error));
    } finally {
      this.isConnecting = false;
    }
  }

  async handleDisconnect() {
    try {
      this.status = await disconnect();
      this.toast("success", "Your GitHub account is disconnected.");
    } catch (error) {
      this.toast("error", reduceError(error));
    }
  }

  toast(variant, message) {
    this.dispatchEvent(
      new ShowToastEvent({
        title:
          variant === "error" ? "Something went wrong" : "GitHub MCP Setup",
        message,
        variant
      })
    );
  }
}
