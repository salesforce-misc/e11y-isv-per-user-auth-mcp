/**
 * Controller for the `githubMcpSetup` LWC on the GitHub MCP Setup app page.
 *
 * Walks a subscriber admin through post-install setup:
 *   1. Confirms the running user can use the Per-User Principal (principal
 *      access plus Read on `UserExternalCredential`).
 *   2. Shows the provider's callback URL for the GitHub OAuth App.
 *   3. Saves the OAuth App's client ID and secret to the packaged External
 *      Auth Identity Provider.
 *   4. Starts the running user's own GitHub OAuth flow and reports its status.
 *
 * Every method requires the `GitHub_MCP_Setup_Admin` custom permission,
 * which ships in the `GitHub_MCP_Setup` permission set. The client secret
 * is accepted on save and never returned.
 */
public with sharing class GitHubMcpSetupController {
  @TestVisible
  private static final String SETUP_PERMISSION = 'GitHub_MCP_Setup_Admin';

  @TestVisible
  private static final String SETUP_TAB = 'GitHub_MCP_Setup';

  @TestVisible
  private static final String USER_PERM_SET = 'GitHub_Perm_Set';

  /** Reported instead of a credential status when the user can't use the principal. */
  @TestVisible
  private static final String STATUS_NO_ACCESS = 'NoAccess';

  private static final String UEC_SOBJECT = 'UserExternalCredential';

  /** Upper bound on client ID and secret input; GitHub's values are far shorter. */
  private static final Integer MAX_CREDENTIAL_LENGTH = 255;

  @TestVisible
  private static GitHubMcpCredentialService service = new GitHubMcpCredentialService();

  public class SetupStatus {
    @AuraEnabled
    public Boolean hasPrincipalAccess;
    @AuraEnabled
    public Boolean hasUecAccess;
    @AuraEnabled
    public Id userPermSetId;
    @AuraEnabled
    public String callbackUrl;
    @AuraEnabled
    public String clientId;
    @AuraEnabled
    public Boolean clientSecretConfigured;
    @AuraEnabled
    public String authenticationStatus;
  }

  @AuraEnabled
  public static SetupStatus getSetupStatus() {
    requireSetupPermission();
    try {
      return buildStatus();
    } catch (Exception e) {
      throw auraError('Could not read the GitHub MCP setup status.', e);
    }
  }

  @AuraEnabled
  public static SetupStatus saveClientCredentials(
    String clientId,
    String clientSecret
  ) {
    requireSetupPermission();
    String trimmedId = clientId == null ? null : clientId.trim();
    String trimmedSecret = clientSecret == null ? null : clientSecret.trim();
    if (String.isBlank(trimmedId) || String.isBlank(trimmedSecret)) {
      throw auraError('Enter both the client ID and the client secret.');
    }
    if (
      trimmedId.length() > MAX_CREDENTIAL_LENGTH ||
      trimmedSecret.length() > MAX_CREDENTIAL_LENGTH
    ) {
      throw auraError('The client ID or client secret is too long.');
    }

    try {
      GitHubMcpCredentialService.ProviderState current = service.getProviderState();
      Boolean replaceExisting =
        current.clientId != null || current.clientSecretConfigured;
      service.saveClientCredentials(trimmedId, trimmedSecret, replaceExisting);
      return buildStatus();
    } catch (Exception e) {
      throw auraError('Could not save the client credentials.', e);
    }
  }

  /**
   * Returns the GitHub authorize URL for the running user. The return URL
   * is built here, not taken from the client, so the flow can only land
   * back on this org's setup tab.
   */
  @AuraEnabled
  public static String getAuthenticationUrl() {
    requireSetupPermission();
    try {
      return service.getAuthenticationUrl(setupTabUrl());
    } catch (Exception e) {
      throw auraError('Could not start GitHub authentication.', e);
    }
  }

  /** Removes the running user's stored GitHub token. */
  @AuraEnabled
  public static SetupStatus disconnect() {
    requireSetupPermission();
    try {
      service.deleteUserCredential();
      return buildStatus();
    } catch (Exception e) {
      throw auraError('Could not disconnect the GitHub account.', e);
    }
  }

  @TestVisible
  private static String setupTabUrl() {
    return URL.getOrgDomainUrl().toExternalForm() +
      '/lightning/n/' +
      GitHubMcpCredentialService.qualify(SETUP_TAB);
  }

  private static SetupStatus buildStatus() {
    GitHubMcpCredentialService.ProviderState provider = service.getProviderState();
    Set<Id> assignedPermSetIds = assignedPermissionSetIds();

    SetupStatus status = new SetupStatus();
    status.callbackUrl = provider.callbackUrl;
    status.clientId = provider.clientId;
    status.clientSecretConfigured = provider.clientSecretConfigured;
    status.hasPrincipalAccess = hasPrincipalAccess(
      service.getPrincipalId(),
      assignedPermSetIds
    );
    status.hasUecAccess = hasUecReadAccess(assignedPermSetIds);
    status.userPermSetId = findUserPermSetId();
    // Reading a per-user credential without principal access fails, so
    // report the missing access instead of calling the API.
    status.authenticationStatus = status.hasPrincipalAccess
      ? service.getUserAuthenticationStatus()
      : STATUS_NO_ACCESS;
    return status;
  }

  /** Permission sets assigned to the running user, including the one owned by their profile. */
  private static Set<Id> assignedPermissionSetIds() {
    Set<Id> ids = new Set<Id>();
    for (PermissionSetAssignment psa : [
      SELECT PermissionSetId
      FROM PermissionSetAssignment
      WHERE AssigneeId = :UserInfo.getUserId()
    ]) {
      ids.add(psa.PermissionSetId);
    }
    return ids;
  }

  private static Boolean hasPrincipalAccess(
    Id principalId,
    Set<Id> assignedPermSetIds
  ) {
    if (principalId == null || assignedPermSetIds.isEmpty()) {
      return false;
    }
    return [
        SELECT COUNT()
        FROM SetupEntityAccess
        WHERE SetupEntityId = :principalId AND ParentId IN :assignedPermSetIds
      ] > 0;
  }

  /**
   * `UserExternalCredential` isn't available through Schema describe, so
   * read access is checked from the object permissions of the user's
   * permission sets.
   */
  private static Boolean hasUecReadAccess(Set<Id> assignedPermSetIds) {
    if (assignedPermSetIds.isEmpty()) {
      return false;
    }
    return [
        SELECT COUNT()
        FROM ObjectPermissions
        WHERE
          ParentId IN :assignedPermSetIds
          AND SobjectType = :UEC_SOBJECT
          AND PermissionsRead = TRUE
      ] > 0;
  }

  private static Id findUserPermSetId() {
    List<PermissionSet> sets = [
      SELECT Id
      FROM PermissionSet
      WHERE
        Name = :USER_PERM_SET
        AND NamespacePrefix = :GitHubMcpCredentialService.PACKAGE_NAMESPACE
      LIMIT 1
    ];
    return sets.isEmpty() ? null : sets[0].Id;
  }

  private static void requireSetupPermission() {
    if (!FeatureManagement.checkPermission(SETUP_PERMISSION)) {
      throw auraError(
        'You need the GitHub MCP - Setup Admin permission set to use this page.'
      );
    }
  }

  private static AuraHandledException auraError(String message) {
    AuraHandledException error = new AuraHandledException(message);
    // Without setMessage, getMessage() returns "Script-thrown exception".
    error.setMessage(message);
    return error;
  }

  /**
   * Appends the underlying error so admins can act on it. The client
   * secret is never part of a ConnectApi error message.
   */
  private static AuraHandledException auraError(String message, Exception e) {
    return auraError(message + ' ' + e.getMessage());
  }
}
