import { createElement } from "lwc";
import GithubMcpSetup from "c/githubMcpSetup";
import getSetupStatus from "@salesforce/apex/GitHubMcpSetupController.getSetupStatus";
import saveClientCredentials from "@salesforce/apex/GitHubMcpSetupController.saveClientCredentials";
import getAuthenticationUrl from "@salesforce/apex/GitHubMcpSetupController.getAuthenticationUrl";

jest.mock(
  "@salesforce/apex/GitHubMcpSetupController.getSetupStatus",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/GitHubMcpSetupController.saveClientCredentials",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/GitHubMcpSetupController.getAuthenticationUrl",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/GitHubMcpSetupController.disconnect",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const CALLBACK_URL = "https://test.salesforce.com/services/extidp/callback";

function statusWith(overrides) {
  return {
    hasPrincipalAccess: true,
    hasUecAccess: true,
    userPermSetId: "0PS000000000001AAA",
    callbackUrl: CALLBACK_URL,
    clientId: null,
    clientSecretConfigured: false,
    authenticationStatus: "NotConfigured",
    ...overrides
  };
}

// Lets pending Apex promises and the re-render that follows settle.
function flushPromises() {
  // eslint-disable-next-line @lwc/lwc/no-async-operation
  return new Promise((resolve) => setTimeout(resolve, 0));
}

async function render(status) {
  getSetupStatus.mockResolvedValue(status);
  const element = createElement("c-github-mcp-setup", { is: GithubMcpSetup });
  document.body.appendChild(element);
  await flushPromises();
  return element;
}

function query(element, selector) {
  return element.shadowRoot.querySelector(selector);
}

function stepStates(element) {
  const states = {};
  element.shadowRoot
    .querySelectorAll("c-github-mcp-setup-step")
    .forEach((step) => {
      states[step.dataset.step] = step.state;
    });
  return states;
}

async function typeInto(element, selector, value) {
  const input = query(element, selector);
  input.value = value;
  input.dispatchEvent(new CustomEvent("change", { detail: { value } }));
  await flushPromises();
}

describe("c-github-mcp-setup", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("starts on the permissions step when access is missing", async () => {
    const element = await render(
      statusWith({
        hasPrincipalAccess: false,
        authenticationStatus: "NoAccess"
      })
    );

    expect(stepStates(element)).toEqual({
      permissions: "current",
      oauthApp: "upcoming",
      credentials: "upcoming",
      authenticate: "upcoming",
      next: "upcoming"
    });
    expect(query(element, ".permission-help")).not.toBeNull();
    expect(query(element, ".connect-button").disabled).toBe(true);
  });

  it("shows the callback URL and the instructions on the OAuth App step", async () => {
    const element = await render(statusWith());

    expect(stepStates(element)).toMatchObject({
      permissions: "complete",
      oauthApp: "current",
      credentials: "upcoming"
    });
    expect(query(element, ".progress-summary").textContent).toContain(
      "1 of 4 setup steps done. Next: Create a GitHub OAuth App."
    );
    expect(query(element, ".callback-url").value).toBe(CALLBACK_URL);
    expect(query(element, ".oauth-instructions")).not.toBeNull();
    expect(query(element, ".oauth-instructions-toggle")).toBeNull();
    expect(query(element, ".permission-help")).toBeNull();
  });

  it("saves credentials, clears the secret, and collapses the form", async () => {
    const element = await render(statusWith());
    saveClientCredentials.mockResolvedValue(
      statusWith({ clientId: "Iv1.test", clientSecretConfigured: true })
    );

    expect(query(element, ".save-button").disabled).toBe(true);
    await typeInto(element, ".client-id", "Iv1.test");
    await typeInto(element, ".client-secret", "s3cret");
    expect(query(element, ".save-button").disabled).toBe(false);

    query(element, ".save-button").click();
    await flushPromises();

    expect(saveClientCredentials).toHaveBeenCalledWith({
      clientId: "Iv1.test",
      clientSecret: "s3cret"
    });
    expect(query(element, ".client-secret")).toBeNull();
    expect(query(element, ".credentials-summary").textContent).toContain(
      "Iv1.test"
    );
    expect(query(element, ".oauth-instructions")).toBeNull();
    expect(stepStates(element)).toMatchObject({
      oauthApp: "complete",
      credentials: "complete",
      authenticate: "current"
    });
  });

  it("reopens the credentials form to replace them, and cancels", async () => {
    const element = await render(
      statusWith({ clientId: "Iv1.test", clientSecretConfigured: true })
    );

    query(element, ".replace-button").click();
    await flushPromises();

    expect(query(element, ".client-id").value).toBe("Iv1.test");
    expect(query(element, ".save-button").label).toBe("Replace credentials");

    await typeInto(element, ".client-secret", "typed-but-cancelled");
    query(element, ".cancel-replace-button").click();
    await flushPromises();

    expect(query(element, ".client-secret")).toBeNull();
    expect(query(element, ".replace-button")).not.toBeNull();
  });

  it("toggles the OAuth App instructions once credentials are saved", async () => {
    const element = await render(
      statusWith({ clientId: "Iv1.test", clientSecretConfigured: true })
    );

    expect(query(element, ".oauth-instructions")).toBeNull();
    query(element, ".oauth-instructions-toggle").click();
    await flushPromises();
    expect(query(element, ".oauth-instructions")).not.toBeNull();
  });

  it("opens GitHub in a new tab and refreshes when the admin returns", async () => {
    const element = await render(
      statusWith({ clientId: "Iv1.test", clientSecretConfigured: true })
    );
    const authWindow = { location: { href: "" }, close: jest.fn() };
    const openSpy = jest.spyOn(window, "open").mockReturnValue(authWindow);
    getAuthenticationUrl.mockResolvedValue(
      "https://github.com/login/oauth/authorize?x=1"
    );

    query(element, ".connect-button").click();
    await flushPromises();

    expect(openSpy).toHaveBeenCalledWith("", "_blank");
    expect(authWindow.location.href).toBe(
      "https://github.com/login/oauth/authorize?x=1"
    );

    getSetupStatus.mockResolvedValue(
      statusWith({
        clientId: "Iv1.test",
        clientSecretConfigured: true,
        authenticationStatus: "Configured"
      })
    );
    document.dispatchEvent(new CustomEvent("visibilitychange"));
    await flushPromises();

    expect(getSetupStatus).toHaveBeenCalledTimes(2);
    expect(stepStates(element)).toMatchObject({
      authenticate: "complete",
      next: "current"
    });
    expect(query(element, ".progress-summary").textContent).toContain(
      "Setup is done."
    );
    expect(query(element, ".connect-button").label).toBe("Reconnect GitHub");
    expect(query(element, ".disconnect-button")).not.toBeNull();
    openSpy.mockRestore();
  });

  it("links the next steps to Agentforce Registry in a new tab", async () => {
    const element = await render(statusWith());

    const link = query(element, ".registry-link");
    expect(link.getAttribute("href")).toBe(
      "/lightning/setup/AgentforceRegistry/home"
    );
    expect(link.target).toBe("_blank");
  });

  it("shows an error when the status can't be loaded", async () => {
    getSetupStatus.mockRejectedValue({ body: { message: "No access." } });
    const element = createElement("c-github-mcp-setup", { is: GithubMcpSetup });
    document.body.appendChild(element);
    await flushPromises();

    expect(query(element, ".error-message").textContent).toBe("No access.");
  });
});
