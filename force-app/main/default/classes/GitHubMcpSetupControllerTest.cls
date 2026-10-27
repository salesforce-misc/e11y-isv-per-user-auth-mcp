/**
 * Tests for {@link GitHubMcpSetupController}.
 *
 * ConnectApi Named Credentials methods can't run in tests, so each test
 * swaps in {@link StubService}. Access checks run against real
 * permission sets: the packaged `GitHub_MCP_Setup` (custom permission)
 * and `GitHub_Perm_Set` (principal access and UEC), assigned to a test
 * user that each test runs as.
 */
@IsTest
private class GitHubMcpSetupControllerTest {
  private static final String SETUP_USERNAME =
    'ghmcp.setup.admin@ghmcptest' +
    String.valueOf(UserInfo.getOrganizationId()).toLowerCase() +
    '.invalid';
  private static final String SETUP_PERM_SET = 'GitHub_MCP_Setup';

  private class StubException extends Exception {
  }

  private class StubService extends GitHubMcpCredentialService {
    GitHubMcpCredentialService.ProviderState state = new GitHubMcpCredentialService.ProviderState();
    Id principalId;
    String authenticationStatus = 'NotConfigured';
    Exception failWith;

    String savedClientId;
    String savedClientSecret;
    Boolean savedWithReplace;
    String requestedReturnUrl;
    Boolean deleted = false;

    public override GitHubMcpCredentialService.ProviderState getProviderState() {
      return state;
    }

    public override void saveClientCredentials(
      String clientId,
      String clientSecret,
      Boolean replaceExisting
    ) {
      if (failWith != null) {
        throw failWith;
      }
      savedClientId = clientId;
      savedClientSecret = clientSecret;
      savedWithReplace = replaceExisting;
      state.clientId = clientId;
      state.clientSecretConfigured = true;
    }

    public override Id getPrincipalId() {
      return principalId;
    }

    public override String getUserAuthenticationStatus() {
      return authenticationStatus;
    }

    public override String getAuthenticationUrl(String returnUrl) {
      requestedReturnUrl = returnUrl;
      return 'https://github.com/login/oauth/authorize?client_id=test';
    }

    public override void deleteUserCredential() {
      deleted = true;
      authenticationStatus = 'NotConfigured';
    }
  }

  @TestSetup
  static void setupTestData() {
    Profile standard = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User admin = new User(
      FirstName = 'GHMCP',
      LastName = 'Setup Admin',
      Email = SETUP_USERNAME,
      Username = SETUP_USERNAME,
      Alias = 'ghsetup',
      TimeZoneSidKey = 'America/Los_Angeles',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      ProfileId = standard.Id
    );
    insert admin;
  }

  @IsTest
  static void getSetupStatus_reportsProviderAndAccess() {
    StubService stub = installStub();
    stub.state.callbackUrl = 'https://test.salesforce.com/services/extidp/callback';
    stub.state.clientId = 'Iv1.test';
    stub.state.clientSecretConfigured = true;
    stub.principalId = packagedPrincipalId();
    stub.authenticationStatus = 'Configured';
    User admin = setupAdmin(true);

    GitHubMcpSetupController.SetupStatus status;
    Test.startTest();
    System.runAs(admin) {
      status = GitHubMcpSetupController.getSetupStatus();
    }
    Test.stopTest();

    System.assertEquals(
      stub.state.callbackUrl,
      status.callbackUrl,
      'The provider callback URL should be returned.'
    );
    System.assertEquals(
      'Iv1.test',
      status.clientId,
      'Client ID should be returned.'
    );
    System.assert(
      status.clientSecretConfigured,
      'The page should know a client secret is saved.'
    );
    System.assert(
      status.hasPrincipalAccess,
      'GitHub_Perm_Set grants principal access.'
    );
    System.assert(status.hasUecAccess, 'GitHub_Perm_Set grants UEC Read.');
    System.assertEquals(
      packagedPermSetId(GitHubMcpSetupController.USER_PERM_SET),
      status.userPermSetId,
      'The packaged user permission set should be returned for the assignment link.'
    );
    System.assertEquals(
      'Configured',
      status.authenticationStatus,
      'The running user\'s credential status should be returned.'
    );
  }

  @IsTest
  static void getSetupStatus_reportsMissingAccessWithoutCallingCredentialApi() {
    StubService stub = installStub();
    stub.principalId = packagedPrincipalId();
    stub.authenticationStatus = 'Configured';
    User admin = setupAdmin(false);

    GitHubMcpSetupController.SetupStatus status;
    Test.startTest();
    System.runAs(admin) {
      status = GitHubMcpSetupController.getSetupStatus();
    }
    Test.stopTest();

    System.assert(
      !status.hasPrincipalAccess,
      'Without GitHub_Perm_Set the user has no principal access.'
    );
    // hasUecAccess isn't asserted: some orgs grant UEC Read through the
    // Standard User profile.
    System.assertEquals(
      GitHubMcpSetupController.STATUS_NO_ACCESS,
      status.authenticationStatus,
      'Missing principal access should be reported instead of a credential status.'
    );
  }

  @IsTest
  static void everyMethod_requiresSetupPermission() {
    installStub();
    User noSetup = [SELECT Id FROM User WHERE Username = :SETUP_USERNAME];

    Integer denied = 0;
    Test.startTest();
    System.runAs(noSetup) {
      try {
        GitHubMcpSetupController.getSetupStatus();
      } catch (AuraHandledException e) {
        denied++;
      }
      try {
        GitHubMcpSetupController.saveClientCredentials('id', 'secret');
      } catch (AuraHandledException e) {
        denied++;
      }
      try {
        GitHubMcpSetupController.getAuthenticationUrl();
      } catch (AuraHandledException e) {
        denied++;
      }
      try {
        GitHubMcpSetupController.disconnect();
      } catch (AuraHandledException e) {
        denied++;
      }
    }
    Test.stopTest();

    System.assertEquals(
      4,
      denied,
      'Every method should reject a user without the setup custom permission.'
    );
  }

  @IsTest
  static void saveClientCredentials_createsTrimmedCredentialsOnFirstSave() {
    StubService stub = installStub();
    User admin = setupAdmin(true);

    GitHubMcpSetupController.SetupStatus status;
    Test.startTest();
    System.runAs(admin) {
      status = GitHubMcpSetupController.saveClientCredentials(
        '  Iv1.test ',
        ' s3cret  '
      );
    }
    Test.stopTest();

    System.assertEquals(
      'Iv1.test',
      stub.savedClientId,
      'Client ID should be trimmed.'
    );
    System.assertEquals(
      's3cret',
      stub.savedClientSecret,
      'Client secret should be trimmed.'
    );
    System.assert(
      !stub.savedWithReplace,
      'A provider with no credentials should get them created, not updated.'
    );
    System.assert(
      status.clientSecretConfigured,
      'The returned status should reflect the save.'
    );
  }

  @IsTest
  static void saveClientCredentials_replacesExistingCredentials() {
    StubService stub = installStub();
    stub.state.clientId = 'Iv1.old';
    stub.state.clientSecretConfigured = true;
    User admin = setupAdmin(true);

    Test.startTest();
    System.runAs(admin) {
      GitHubMcpSetupController.saveClientCredentials('Iv1.new', 'new-secret');
    }
    Test.stopTest();

    System.assert(
      stub.savedWithReplace,
      'Existing credentials should be updated, not created again.'
    );
    System.assertEquals(
      'Iv1.new',
      stub.savedClientId,
      'The new client ID should be saved.'
    );
  }

  @IsTest
  static void saveClientCredentials_rejectsBlankAndOverlongInput() {
    StubService stub = installStub();
    User admin = setupAdmin(true);

    List<String> messages = new List<String>();
    Test.startTest();
    System.runAs(admin) {
      for (
        List<String> pair : new List<List<String>>{
          new List<String>{ '', 'secret' },
          new List<String>{ 'id', '   ' },
          new List<String>{ null, null },
          new List<String>{ 'id', 'x'.repeat(256) }
        }
      ) {
        try {
          GitHubMcpSetupController.saveClientCredentials(pair[0], pair[1]);
        } catch (AuraHandledException e) {
          messages.add(e.getMessage());
        }
      }
    }
    Test.stopTest();

    System.assertEquals(
      4,
      messages.size(),
      'Blank and overlong credentials should be rejected.'
    );
    System.assert(
      messages[3].contains('too long'),
      'Overlong input should get its own message: ' + messages[3]
    );
    System.assertEquals(
      null,
      stub.savedClientId,
      'Nothing should reach the provider when validation fails.'
    );
  }

  @IsTest
  static void saveClientCredentials_reportsServiceErrors() {
    StubService stub = installStub();
    stub.failWith = new StubException('Provider is locked.');
    User admin = setupAdmin(true);

    String message;
    Test.startTest();
    System.runAs(admin) {
      try {
        GitHubMcpSetupController.saveClientCredentials('Iv1.test', 's3cret');
      } catch (AuraHandledException e) {
        message = e.getMessage();
      }
    }
    Test.stopTest();

    System.assert(
      message != null && message.contains('Provider is locked.'),
      'The underlying error should reach the admin: ' + message
    );
    System.assert(
      !message.contains('s3cret'),
      'The client secret must never appear in an error message.'
    );
  }

  @IsTest
  static void getAuthenticationUrl_returnsToTheSetupTab() {
    StubService stub = installStub();
    User admin = setupAdmin(true);

    String authUrl;
    Test.startTest();
    System.runAs(admin) {
      authUrl = GitHubMcpSetupController.getAuthenticationUrl();
    }
    Test.stopTest();

    System.assert(
      authUrl.startsWith('https://github.com/'),
      'The service URL should be returned.'
    );
    System.assertEquals(
      URL.getOrgDomainUrl().toExternalForm() +
        '/lightning/n/' +
        GitHubMcpCredentialService.qualify(GitHubMcpSetupController.SETUP_TAB),
      stub.requestedReturnUrl,
      'The OAuth flow should return to this org\'s setup tab.'
    );
  }

  @IsTest
  static void disconnect_deletesTheUserCredential() {
    StubService stub = installStub();
    stub.principalId = packagedPrincipalId();
    stub.authenticationStatus = 'Configured';
    User admin = setupAdmin(true);

    GitHubMcpSetupController.SetupStatus status;
    Test.startTest();
    System.runAs(admin) {
      status = GitHubMcpSetupController.disconnect();
    }
    Test.stopTest();

    System.assert(stub.deleted, 'The user credential should be deleted.');
    System.assertEquals(
      'NotConfigured',
      status.authenticationStatus,
      'The returned status should reflect the disconnect.'
    );
  }

  private static StubService installStub() {
    StubService stub = new StubService();
    GitHubMcpSetupController.service = stub;
    return stub;
  }

  /** The test user with the setup permission set and, optionally, GitHub_Perm_Set. */
  private static User setupAdmin(Boolean withUserPermSet) {
    User admin = [SELECT Id FROM User WHERE Username = :SETUP_USERNAME];
    List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>{
      new PermissionSetAssignment(
        AssigneeId = admin.Id,
        PermissionSetId = packagedPermSetId(SETUP_PERM_SET)
      )
    };
    if (withUserPermSet) {
      assignments.add(
        new PermissionSetAssignment(
          AssigneeId = admin.Id,
          PermissionSetId = packagedPermSetId(
            GitHubMcpSetupController.USER_PERM_SET
          )
        )
      );
    }
    insert assignments;
    return admin;
  }

  private static Id packagedPermSetId(String developerName) {
    return [
      SELECT Id
      FROM PermissionSet
      WHERE
        Name = :developerName
        AND NamespacePrefix = :GitHubMcpCredentialService.PACKAGE_NAMESPACE
      LIMIT 1
    ]
    .Id;
  }

  /** The Per-User Principal, read from GitHub_Perm_Set's principal access row. */
  private static Id packagedPrincipalId() {
    return [
      SELECT SetupEntityId
      FROM SetupEntityAccess
      WHERE
        ParentId = :packagedPermSetId(GitHubMcpSetupController.USER_PERM_SET)
        AND SetupEntityType = 'ExternalCredentialParameter'
      LIMIT 1
    ]
    .SetupEntityId;
  }
}
