/**
 * Thin wrapper around the Named Credentials Connect API calls that the
 * GitHub MCP setup page makes against the packaged External Auth Identity
 * Provider (`GitHubAuth`) and External Credential (`GitHub`).
 *
 * ConnectApi Named Credentials methods can't run in Apex tests, so this
 * class is `virtual` and holds no logic beyond mapping to and from
 * ConnectApi types. Tests replace it with a stub subclass through
 * `GitHubMcpSetupController.service`.
 *
 * Connect API names must carry the package namespace
 * (`mvpbo3__GitHubAuth`).
 */
public virtual with sharing class GitHubMcpCredentialService {
  /** The managed package's namespace, fixed when the package was created. */
  public static final String PACKAGE_NAMESPACE = 'mvpbo3';

  public static final String PROVIDER_NAME = 'GitHubAuth';
  public static final String EXTERNAL_CREDENTIAL_NAME = 'GitHub';
  public static final String PRINCIPAL_NAME = 'PerUserAccountAccess';

  private static final String CLIENT_ID = 'clientId';
  private static final String CLIENT_SECRET = 'clientSecret';

  /** What the setup page needs to know about the provider. Never holds the secret. */
  public class ProviderState {
    public String callbackUrl;
    public String clientId;
    public Boolean clientSecretConfigured = false;
  }

  public virtual ProviderState getProviderState() {
    ConnectApi.ExternalAuthIdentityProvider provider = ConnectApi.NamedCredentials.getExternalAuthIdentityProvider(
      qualify(PROVIDER_NAME)
    );
    ProviderState state = new ProviderState();
    state.callbackUrl = provider.callbackUrl;
    if (provider.credentials != null) {
      for (
        ConnectApi.ExternalAuthIdentityProviderCredential credential : provider.credentials
      ) {
        if (credential.credentialName == CLIENT_ID) {
          state.clientId = credential.credentialValue;
        } else if (credential.credentialName == CLIENT_SECRET) {
          // The API never returns the secret's value, only that it exists.
          state.clientSecretConfigured = true;
        }
      }
    }
    return state;
  }

  /**
   * Writes the GitHub OAuth App's client ID and secret to the provider.
   * The provider ships without credentials, so the first save creates them
   * and later saves replace them.
   */
  public virtual void saveClientCredentials(
    String clientId,
    String clientSecret,
    Boolean replaceExisting
  ) {
    ConnectApi.ExternalAuthIdentityProviderCredentialsInput input = new ConnectApi.ExternalAuthIdentityProviderCredentialsInput();
    input.credentials = new List<ConnectApi.ExternalAuthIdentityProviderCredentialInput>{
      credentialInput(CLIENT_ID, clientId),
      credentialInput(CLIENT_SECRET, clientSecret)
    };
    if (replaceExisting) {
      ConnectApi.NamedCredentials.updateExternalAuthIdentityProviderCredentials(
        qualify(PROVIDER_NAME),
        input
      );
    } else {
      ConnectApi.NamedCredentials.createExternalAuthIdentityProviderCredentials(
        qualify(PROVIDER_NAME),
        input
      );
    }
  }

  /** Record Id (`0pu…`) of the Per-User Principal, used to check principal access. */
  public virtual Id getPrincipalId() {
    ConnectApi.ExternalCredential credential = ConnectApi.NamedCredentials.getExternalCredential(
      qualify(EXTERNAL_CREDENTIAL_NAME)
    );
    if (credential.principals != null) {
      for (
        ConnectApi.ExternalCredentialPrincipal principal : credential.principals
      ) {
        if (principal.principalName == PRINCIPAL_NAME) {
          return principal.id;
        }
      }
    }
    return null;
  }

  /** The running user's authentication status, such as `Configured` or `NotConfigured`. */
  public virtual String getUserAuthenticationStatus() {
    ConnectApi.Credential credential = ConnectApi.NamedCredentials.getCredential(
      qualify(EXTERNAL_CREDENTIAL_NAME),
      PRINCIPAL_NAME,
      ConnectApi.CredentialPrincipalType.PerUserPrincipal
    );
    return String.valueOf(credential.authenticationStatus);
  }

  /** GitHub authorize URL that starts the OAuth flow for the running user. */
  public virtual String getAuthenticationUrl(String returnUrl) {
    ConnectApi.OAuthCredentialAuthUrlInput input = new ConnectApi.OAuthCredentialAuthUrlInput();
    input.externalCredential = qualify(EXTERNAL_CREDENTIAL_NAME);
    input.principalName = PRINCIPAL_NAME;
    input.principalType = ConnectApi.CredentialPrincipalType.PerUserPrincipal;
    input.returnUrl = returnUrl;
    // ConnectApi HTML-escapes string output, so the query string comes
    // back with `&amp;` separators.
    return ConnectApi.NamedCredentials.getOAuthCredentialAuthUrl(input)
      .authenticationUrl.unescapeHtml4();
  }

  /** Deletes the running user's stored GitHub token. The External Credential itself is untouched. */
  public virtual void deleteUserCredential() {
    ConnectApi.NamedCredentials.deleteCredential(
      qualify(EXTERNAL_CREDENTIAL_NAME),
      PRINCIPAL_NAME,
      ConnectApi.CredentialPrincipalType.PerUserPrincipal
    );
  }

  /** Prefixes a packaged component name with the package namespace. */
  public static String qualify(String name) {
    return PACKAGE_NAMESPACE + '__' + name;
  }

  private static ConnectApi.ExternalAuthIdentityProviderCredentialInput credentialInput(
    String name,
    String value
  ) {
    ConnectApi.ExternalAuthIdentityProviderCredentialInput input = new ConnectApi.ExternalAuthIdentityProviderCredentialInput();
    input.credentialName = name;
    input.credentialValue = value;
    return input;
  }
}
