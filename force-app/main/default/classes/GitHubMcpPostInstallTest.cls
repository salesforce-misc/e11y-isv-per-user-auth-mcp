/**
 * Tests for {@link GitHubMcpPostInstall}.
 *
 * The Platform Integration User is identified by the deterministic
 * `cloud@{orgId18}` Username and `noreply@{orgId18}` Email convention.
 * To keep tests independent of whatever real Platform Integration User
 * lives in the running org (whose Username is globally unique and
 * therefore can't be replicated in a fixture), each test creates a
 * stand-in user with a known Username/Email pair and points the
 * `integrationUsernameOverride` / `integrationEmailOverride` statics
 * at it.
 *
 * Fixture permission sets are created by the test, so their namespace
 * depends on the org the tests run in. Each test points
 * `packageNamespace` at the fixture's actual namespace instead of
 * assuming one.
 */
@IsTest
private class GitHubMcpPostInstallTest {
  private static final String ORG_SUFFIX = String.valueOf(
      UserInfo.getOrganizationId()
    )
    .toLowerCase();
  private static final String FAKE_USERNAME =
    'cloud@ghmcptest' + ORG_SUFFIX + '.invalid';
  private static final String FAKE_EMAIL =
    'noreply@ghmcptest' + ORG_SUFFIX + '.invalid';
  private static final String FAKE_EMAIL_ONLY_USERNAME =
    'unrelated.user@ghmcptest' + ORG_SUFFIX + '.invalid';
  private static final String PERMSET_FULL_UEC = 'ghMcpTestPermSetFullUEC';
  private static final String PERMSET_READ_UEC = 'ghMcpTestPermSetReadUEC';
  private static final String PERMSET_NO_UEC = 'ghMcpTestPermSetNoUEC';
  private static final String PERMSET_SETUP = 'ghMcpTestPermSetSetup';
  private static final String UEC_SOBJECT = 'UserExternalCredential';

  @TestSetup
  static void setupTestData() {
    insert newStandardUser(FAKE_USERNAME, FAKE_EMAIL, 'cghmcp');

    PermissionSet fullUec = new PermissionSet(
      Name = PERMSET_FULL_UEC,
      Label = 'GH MCP Test PermSet (full UEC)'
    );
    PermissionSet readUec = new PermissionSet(
      Name = PERMSET_READ_UEC,
      Label = 'GH MCP Test PermSet (UEC read only)'
    );
    PermissionSet noUec = new PermissionSet(
      Name = PERMSET_NO_UEC,
      Label = 'GH MCP Test PermSet (no UEC)'
    );
    PermissionSet setup = new PermissionSet(
      Name = PERMSET_SETUP,
      Label = 'GH MCP Test PermSet (setup page)'
    );
    insert new List<PermissionSet>{ fullUec, readUec, noUec, setup };

    insert new List<ObjectPermissions>{
      new ObjectPermissions(
        ParentId = fullUec.Id,
        SobjectType = UEC_SOBJECT,
        PermissionsRead = true,
        PermissionsEdit = true,
        PermissionsDelete = true
      ),
      new ObjectPermissions(
        ParentId = readUec.Id,
        SobjectType = UEC_SOBJECT,
        PermissionsRead = true
      )
    };
  }

  @IsTest
  static void onInstall_assignsPackagePermSetWhenItHasFullUecAccess() {
    configureForUsernameLookup(PERMSET_FULL_UEC);

    Id packagePermSetId = permSetId(PERMSET_FULL_UEC);
    Id installerId = UserInfo.getUserId();
    Id integrationUserId = userIdByUsername(FAKE_USERNAME);

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    Set<Id> assignees = collectAssignees(packagePermSetId);
    System.assert(
      assignees.contains(installerId),
      'Installer should be assigned the package permission set.'
    );
    System.assert(
      assignees.contains(integrationUserId),
      'Platform Integration stand-in user should be assigned the package permission set.'
    );
    System.assertEquals(
      0,
      countPermSetByName(GitHubMcpPostInstall.fallbackPermSetName),
      'Fallback permission set should not be created when the package perm set already has full UEC access.'
    );
  }

  @IsTest
  static void onInstall_assignsSetupPermSetToInstallerOnly() {
    configureForUsernameLookup(PERMSET_FULL_UEC);
    GitHubMcpPostInstall.setupPermSetName = PERMSET_SETUP;

    Id setupPermSetId = permSetId(PERMSET_SETUP);
    Id installerId = UserInfo.getUserId();
    Id integrationUserId = userIdByUsername(FAKE_USERNAME);

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    Set<Id> assignees = collectAssignees(setupPermSetId);
    System.assert(
      assignees.contains(installerId),
      'Installer should be assigned the setup permission set.'
    );
    System.assert(
      !assignees.contains(integrationUserId),
      'The Platform Integration User should not be assigned the setup permission set.'
    );
  }

  @IsTest
  static void onInstall_completesWhenSetupPermSetIsMissing() {
    configureForUsernameLookup(PERMSET_FULL_UEC);
    GitHubMcpPostInstall.setupPermSetName = 'Does_Not_Exist_GHMCPTest';

    Id packagePermSetId = permSetId(PERMSET_FULL_UEC);

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    System.assert(
      collectAssignees(packagePermSetId).contains(UserInfo.getUserId()),
      'A missing setup permission set must not stop the package permission set assignment.'
    );
  }

  @IsTest
  static void onInstall_createsFallbackWhenPackagePermSetMissingUecAccess() {
    configureForUsernameLookup(PERMSET_NO_UEC);

    Id packagePermSetId = permSetId(PERMSET_NO_UEC);
    Id installerId = UserInfo.getUserId();
    Id integrationUserId = userIdByUsername(FAKE_USERNAME);

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    System.assert(
      collectAssignees(packagePermSetId).contains(installerId),
      'Installer should still be assigned the package permission set for its principal access.'
    );

    Id fallbackId = singleFallbackId();
    assertFullUecAccess(fallbackId);

    Set<Id> fallbackAssignees = collectAssignees(fallbackId);
    System.assert(
      fallbackAssignees.contains(installerId),
      'Installer should be assigned the fallback permission set.'
    );
    System.assert(
      fallbackAssignees.contains(integrationUserId),
      'Platform Integration stand-in user should be assigned the fallback permission set.'
    );
  }

  @IsTest
  static void onInstall_createsFallbackWhenPackagePermSetHasOnlyUecRead() {
    configureForUsernameLookup(PERMSET_READ_UEC);

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    Id fallbackId = singleFallbackId();
    assertFullUecAccess(fallbackId);
    System.assert(
      collectAssignees(fallbackId).contains(UserInfo.getUserId()),
      'Installer should be assigned the fallback when the package perm set has only partial UEC access.'
    );
  }

  @IsTest
  static void onInstall_isIdempotentOnSecondRun() {
    configureForUsernameLookup(PERMSET_NO_UEC);

    Id packagePermSetId = permSetId(PERMSET_NO_UEC);

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Integer firstRunPackageCount = countAssignments(packagePermSetId);
    Id fallbackId = singleFallbackId();
    Integer firstRunFallbackCount = countAssignments(fallbackId);
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Integer secondRunPackageCount = countAssignments(packagePermSetId);
    Integer secondRunFallbackCount = countAssignments(fallbackId);
    Test.stopTest();

    System.assertEquals(
      firstRunPackageCount,
      secondRunPackageCount,
      'Re-running the post-install must not create duplicate package permission set assignments.'
    );
    System.assertEquals(
      firstRunFallbackCount,
      secondRunFallbackCount,
      'Re-running the post-install must not create duplicate fallback permission set assignments.'
    );
    System.assertEquals(
      1,
      countPermSetByName(GitHubMcpPostInstall.fallbackPermSetName),
      'Re-running the post-install must not create a second fallback permission set.'
    );
  }

  @IsTest
  static void onInstall_reusesExistingFallbackPermissionSet() {
    configureForUsernameLookup(PERMSET_NO_UEC);

    PermissionSet preExisting = new PermissionSet(
      Name = GitHubMcpPostInstall.fallbackPermSetName,
      Label = 'Pre-existing fallback'
    );
    insert preExisting;

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    System.assertEquals(
      1,
      countPermSetByName(GitHubMcpPostInstall.fallbackPermSetName),
      'When a fallback perm set already exists, no duplicate should be created.'
    );
    assertFullUecAccess(preExisting.Id);
    System.assert(
      collectAssignees(preExisting.Id).contains(UserInfo.getUserId()),
      'Installer should be assigned the existing fallback permission set.'
    );
  }

  @IsTest
  static void onInstall_repairsExistingFallbackWithPartialUecAccess() {
    configureForUsernameLookup(PERMSET_NO_UEC);

    PermissionSet preExisting = new PermissionSet(
      Name = GitHubMcpPostInstall.fallbackPermSetName,
      Label = 'Pre-existing fallback (read only)'
    );
    insert preExisting;
    insert new ObjectPermissions(
      ParentId = preExisting.Id,
      SobjectType = UEC_SOBJECT,
      PermissionsRead = true
    );

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    assertFullUecAccess(preExisting.Id);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM ObjectPermissions
        WHERE ParentId = :preExisting.Id AND SobjectType = :UEC_SOBJECT
      ],
      'The existing UEC object permission row should be updated, not duplicated.'
    );
  }

  @IsTest
  static void onInstall_ignoresSameNamedPermSetFromAnotherNamespace() {
    configureForUsernameLookup(PERMSET_FULL_UEC);
    // Simulate a subscriber-owned permission set that shares the packaged
    // name: the handler must not treat it as the packaged one.
    GitHubMcpPostInstall.packageNamespace = 'zzghmcpother';

    Id lookalikeId = permSetId(PERMSET_FULL_UEC);

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    System.assertEquals(
      0,
      countAssignments(lookalikeId),
      'A same-named permission set from another namespace must not be assigned.'
    );
    Id fallbackId = singleFallbackId();
    System.assert(
      collectAssignees(fallbackId).contains(UserInfo.getUserId()),
      'Installer should be assigned the fallback when the packaged perm set is not found.'
    );
  }

  @IsTest
  static void onInstall_handlesMissingPackagePermSetByCreatingFallback() {
    GitHubMcpPostInstall.packagePermSetName = 'Does_Not_Exist_GHMCPTest';
    GitHubMcpPostInstall.integrationUsernameOverride = FAKE_USERNAME;
    GitHubMcpPostInstall.integrationEmailOverride = FAKE_EMAIL;

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    Id fallbackId = singleFallbackId();
    assertFullUecAccess(fallbackId);
    System.assert(
      collectAssignees(fallbackId).contains(UserInfo.getUserId()),
      'Installer should be assigned the fallback when the package perm set is missing.'
    );
  }

  @IsTest
  static void onInstall_completesWhenFallbackPermSetCannotBeCreated() {
    GitHubMcpPostInstall.packagePermSetName = 'Does_Not_Exist_GHMCPTest';
    GitHubMcpPostInstall.integrationUsernameOverride = FAKE_USERNAME;
    GitHubMcpPostInstall.integrationEmailOverride = FAKE_EMAIL;
    // Spaces aren't allowed in a permission set API name, so the insert fails.
    GitHubMcpPostInstall.fallbackPermSetName = 'Invalid Name GHMCPTest';
    GitHubMcpPostInstall handler = new GitHubMcpPostInstall();

    Test.startTest();
    Test.testInstall(handler, new Version(1, 0));
    Integer emailsSent = Limits.getEmailInvocations();
    Test.stopTest();

    System.assertEquals(
      0,
      countPermSetByName(GitHubMcpPostInstall.fallbackPermSetName),
      'No fallback should exist when its insert fails, and the install must not throw.'
    );
    System.assertEquals(
      1,
      handler.problems.size(),
      'The failed fallback insert should be recorded as a problem.'
    );
    System.assert(
      handler.problems[0].contains(GitHubMcpPostInstall.fallbackPermSetName),
      'The problem should name the permission set that could not be created.'
    );
    System.assertEquals(
      1,
      emailsSent,
      'The installer should be emailed the problems.'
    );
  }

  @IsTest
  static void onInstall_sendsNoReportWhenNothingFails() {
    configureForUsernameLookup(PERMSET_FULL_UEC);
    GitHubMcpPostInstall.setupPermSetName = PERMSET_SETUP;
    GitHubMcpPostInstall handler = new GitHubMcpPostInstall();

    Test.startTest();
    Test.testInstall(handler, new Version(1, 0));
    Integer emailsSent = Limits.getEmailInvocations();
    Test.stopTest();

    System.assert(
      handler.problems.isEmpty(),
      'A clean install should record no problems: ' + handler.problems
    );
    System.assertEquals(0, emailsSent, 'A clean install should send no email.');
  }

  @IsTest
  static void recordException_reportsStepAndExceptionDetails() {
    GitHubMcpPostInstall handler = new GitHubMcpPostInstall();

    Test.startTest();
    try {
      Integer zero = 0;
      Integer result = 1 / zero;
    } catch (Exception e) {
      handler.recordException('Test step', e);
    }
    handler.reportProblems(UserInfo.getUserId());
    Integer emailsSent = Limits.getEmailInvocations();
    Test.stopTest();

    System.assertEquals(1, handler.problems.size(), 'One problem expected.');
    System.assert(
      handler.problems[0].startsWith('Test step failed: System.MathException'),
      'The problem should name the step and exception type: ' +
      handler.problems[0]
    );
    System.assertEquals(1, emailsSent, 'The problem should be emailed.');
  }

  @IsTest
  static void reportProblems_skipsEmailWithoutInstaller() {
    GitHubMcpPostInstall handler = new GitHubMcpPostInstall();
    handler.problems.add('Test step failed: example');

    Test.startTest();
    handler.reportProblems(null);
    Integer emailsSent = Limits.getEmailInvocations();
    Test.stopTest();

    System.assertEquals(
      0,
      emailsSent,
      'With no installer there is no one to email.'
    );
  }

  @IsTest
  static void onInstall_skipsIntegrationUserAssignmentWhenNoneMatches() {
    configureForUsernameLookup(PERMSET_FULL_UEC);
    GitHubMcpPostInstall.integrationUsernameOverride = 'cloud@no-such-org-id-zzzzz.invalid';
    GitHubMcpPostInstall.integrationEmailOverride = 'noreply@no-such-org-id-zzzzz.invalid';

    Id packagePermSetId = permSetId(PERMSET_FULL_UEC);
    Id installerId = UserInfo.getUserId();

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    Set<Id> assignees = collectAssignees(packagePermSetId);
    System.assert(
      assignees.contains(installerId),
      'Installer should still be assigned even when no integration user matches.'
    );
    System.assertEquals(
      1,
      assignees.size(),
      'Only the installer should be assigned when no Platform Integration User is found.'
    );
  }

  @IsTest
  static void onInstall_findsUserByEmailWhenUsernameDoesNotMatch() {
    // Insert a user whose Username does NOT match the cloud@ convention
    // but whose Email DOES match the noreply@ convention.
    String emailOnlyAddress = 'noreply@email-only' + ORG_SUFFIX + '.invalid';
    User emailOnly = newStandardUser(
      FAKE_EMAIL_ONLY_USERNAME,
      emailOnlyAddress,
      'emonly'
    );
    insert emailOnly;

    configureForUsernameLookup(PERMSET_FULL_UEC);
    GitHubMcpPostInstall.integrationUsernameOverride = 'cloud@nope-not-the-username.invalid';
    GitHubMcpPostInstall.integrationEmailOverride = emailOnlyAddress;

    Id packagePermSetId = permSetId(PERMSET_FULL_UEC);

    Test.startTest();
    Test.testInstall(new GitHubMcpPostInstall(), new Version(1, 0));
    Test.stopTest();

    System.assert(
      collectAssignees(packagePermSetId).contains(emailOnly.Id),
      'When Username does not match but Email does, the integration user should still be assigned.'
    );
  }

  @IsTest
  static void collectTargetUsers_returnsEmptyWithoutInstallerOrIntegrationUser() {
    GitHubMcpPostInstall.integrationUsernameOverride = 'cloud@no-such-org-id-zzzzz.invalid';
    GitHubMcpPostInstall.integrationEmailOverride = 'noreply@no-such-org-id-zzzzz.invalid';

    Set<Id> users = new GitHubMcpPostInstall().collectTargetUsers(null);

    System.assert(
      users.isEmpty(),
      'No users should be targeted when there is no installer and no integration user.'
    );
  }

  @IsTest
  static void assignPermissionSet_isNoOpForEmptyInput() {
    Id packagePermSetId = permSetId(PERMSET_FULL_UEC);
    GitHubMcpPostInstall handler = new GitHubMcpPostInstall();

    handler.assignPermissionSet(packagePermSetId, new Set<Id>());
    handler.assignPermissionSet(packagePermSetId, null);
    handler.assignPermissionSet(
      null,
      new Set<Id>{ UserInfo.getUserId() }
    );

    System.assertEquals(
      0,
      countAssignments(packagePermSetId),
      'No assignments should be created for empty or null input.'
    );
  }

  @IsTest
  static void getIntegrationUsername_buildsCloudConventionFromOrgId() {
    GitHubMcpPostInstall.integrationUsernameOverride = null;

    System.assertEquals(
      'cloud@' + ORG_SUFFIX,
      GitHubMcpPostInstall.getIntegrationUsername(),
      'Computed integration username should follow cloud@{orgId18-lowercase} convention.'
    );
  }

  @IsTest
  static void getIntegrationEmail_buildsNoreplyConventionFromOrgId() {
    GitHubMcpPostInstall.integrationEmailOverride = null;

    System.assertEquals(
      'noreply@' + ORG_SUFFIX,
      GitHubMcpPostInstall.getIntegrationEmail(),
      'Computed integration email should follow noreply@{orgId18-lowercase} convention.'
    );
  }

  @IsTest
  static void getOrgId18Lower_isAlwaysEighteenLowercaseCharacters() {
    String orgId = GitHubMcpPostInstall.getOrgId18Lower();
    System.assertEquals(
      18,
      orgId.length(),
      'Org id helper must return the 18-character form.'
    );
    System.assertEquals(
      orgId.toLowerCase(),
      orgId,
      'Org id helper must return a lowercase value to match the platform user convention.'
    );
  }

  /** Common configuration helper: target the test perm set fixture (in
   *  whatever namespace the org gave it) and point the integration-user
   *  lookup at the @TestSetup stand-in user.
   */
  private static void configureForUsernameLookup(String permSetName) {
    GitHubMcpPostInstall.packagePermSetName = permSetName;
    GitHubMcpPostInstall.packageNamespace = [
      SELECT NamespacePrefix
      FROM PermissionSet
      WHERE Name = :permSetName
      LIMIT 1
    ]
    .NamespacePrefix;
    GitHubMcpPostInstall.integrationUsernameOverride = FAKE_USERNAME;
    GitHubMcpPostInstall.integrationEmailOverride = FAKE_EMAIL;
  }

  private static User newStandardUser(
    String username,
    String email,
    String alias
  ) {
    Profile standard = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    return new User(
      FirstName = 'GHMCP',
      LastName = 'Test ' + alias,
      Email = email,
      Username = username,
      Alias = alias,
      TimeZoneSidKey = 'America/Los_Angeles',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      ProfileId = standard.Id
    );
  }

  private static Id permSetId(String developerName) {
    return [
      SELECT Id
      FROM PermissionSet
      WHERE Name = :developerName
      LIMIT 1
    ]
    .Id;
  }

  private static Id userIdByUsername(String username) {
    return [SELECT Id FROM User WHERE Username = :username LIMIT 1].Id;
  }

  private static Id singleFallbackId() {
    List<PermissionSet> fallbacks = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = :GitHubMcpPostInstall.fallbackPermSetName
    ];
    System.assertEquals(
      1,
      fallbacks.size(),
      'Exactly one fallback permission set should exist.'
    );
    return fallbacks[0].Id;
  }

  private static void assertFullUecAccess(Id permSetId) {
    List<ObjectPermissions> perms = [
      SELECT
        PermissionsRead,
        PermissionsCreate,
        PermissionsEdit,
        PermissionsDelete
      FROM ObjectPermissions
      WHERE ParentId = :permSetId AND SobjectType = :UEC_SOBJECT
    ];
    System.assertEquals(
      1,
      perms.size(),
      'Permission set should have exactly one UserExternalCredential object permission row.'
    );
    System.assert(perms[0].PermissionsRead, 'UEC Read should be granted.');
    System.assert(perms[0].PermissionsEdit, 'UEC Edit should be granted.');
    System.assert(perms[0].PermissionsDelete, 'UEC Delete should be granted.');
    System.assert(
      !perms[0].PermissionsCreate,
      'UEC Create should not be granted, matching the packaged permission set.'
    );
  }

  private static Set<Id> collectAssignees(Id permSetId) {
    Set<Id> assignees = new Set<Id>();
    for (PermissionSetAssignment psa : [
      SELECT AssigneeId
      FROM PermissionSetAssignment
      WHERE PermissionSetId = :permSetId
    ]) {
      assignees.add(psa.AssigneeId);
    }
    return assignees;
  }

  private static Integer countAssignments(Id permSetId) {
    return [
      SELECT COUNT()
      FROM PermissionSetAssignment
      WHERE PermissionSetId = :permSetId
    ];
  }

  private static Integer countPermSetByName(String developerName) {
    return [SELECT COUNT() FROM PermissionSet WHERE Name = :developerName];
  }
}
