/**
 * Post-install handler for the GitHub MCP (per-user auth) managed package.
 *
 * Responsibilities (each step is idempotent — re-runs and upgrades skip
 * work that is already in place):
 *   1. Assign the packaged permission set (`GitHub_Perm_Set`) to the user
 *      who initiated the install, so that admin can authenticate their own
 *      Per-User Principal and refresh the MCP server's tools.
 *   2. Resolve the Platform Integration User and assign the same
 *      permission set to that user.
 *   3. Assign the setup permission set (`GitHub_MCP_Setup`) to the
 *      installer only, so they can open the GitHub MCP Setup page.
 *   4. Verify the packaged permission set still carries Read, Edit, and
 *      Delete on the `UserExternalCredential` object. If any is missing, create (or
 *      repair) a fallback permission set with them and assign it to the
 *      same users as step 1.
 *
 * Other users are not assigned automatically. With per-user auth, each
 * user connects their own GitHub account, so the subscriber admin decides
 * who gets the permission set.
 *
 * Each step catches its own exceptions, and DML runs with partial success,
 * so one failing step doesn't stop the others or fail the install. Any
 * problem is emailed to the installer instead. A thrown exception would
 * roll back the install, and its details never reach the subscriber: the
 * install only reports "The post install script failed." The setup page
 * shows any permissions that are still missing.
 *
 * Every query and DML statement runs in system mode explicitly. From API
 * version 68.0, Apex database operations default to user mode, and the
 * script runs as the package's own user (user type LicenseManager), which
 * has almost no permissions: in user mode its SOQL on `PermissionSet`
 * fails with "sObject type 'PermissionSet' is not supported".
 *
 * Implemented as `global without sharing` because Salesforce requires the
 * InstallHandler entry point to be `global` and the work performed here
 * must succeed regardless of the installing user's sharing rules.
 */
global without sharing class GitHubMcpPostInstall implements InstallHandler {
  @TestVisible
  private static String packagePermSetName = 'GitHub_Perm_Set';

  /** Grants the GitHub MCP Setup tab and its controller. */
  @TestVisible
  private static String setupPermSetName = 'GitHub_MCP_Setup';

  /**
   * Namespace of the packaged permission sets. Filtering on it keeps the
   * handler from picking up a subscriber's own `GitHub_Perm_Set`, such as
   * the one the UI generates when a subscriber registers an MCP server
   * named "GitHub" themselves. Not final so tests can point it at their
   * fixtures.
   */
  @TestVisible
  private static String packageNamespace = GitHubMcpCredentialService.PACKAGE_NAMESPACE;

  @TestVisible
  private static String fallbackPermSetName = 'GitHub_MCP_UEC_Access';

  @TestVisible
  private static String fallbackPermSetLabel = 'GitHub MCP - UserExternalCredential Access (Post-Install)';

  /**
   * The Platform Integration User follows a deterministic naming convention
   * scoped to each org:
   *   Username = `cloud@{18-character org id, lowercased}`
   *   Email    = `noreply@{18-character org id, lowercased}`
   * Matching on this convention avoids the false positives we would hit by
   * filtering on a `Name LIKE 'Platform%'` style query when a subscriber org
   * happens to have other users whose names start with "Platform".
   */
  @TestVisible
  private static final String INTEGRATION_USERNAME_PREFIX = 'cloud@';

  @TestVisible
  private static final String INTEGRATION_EMAIL_PREFIX = 'noreply@';

  /** Optional overrides used by tests to avoid colliding with the real
   *  Platform Integration User (whose Username is globally unique). */
  @TestVisible
  private static String integrationUsernameOverride;

  @TestVisible
  private static String integrationEmailOverride;

  private static final String UEC_SOBJECT = 'UserExternalCredential';

  /** Problems found during this run, emailed to the installer at the end. */
  @TestVisible
  private List<String> problems = new List<String>();

  global void onInstall(InstallContext context) {
    Id installerId = context.installerId();
    Set<Id> userIds = new Set<Id>();
    Id packagePermSetId;

    try {
      userIds = collectTargetUsers(installerId);
      packagePermSetId = findPackagePermissionSetId(packagePermSetName);
      if (packagePermSetId != null) {
        assignPermissionSet(packagePermSetId, userIds);
      }
    } catch (Exception e) {
      recordException('Assign ' + packagePermSetName, e);
    }

    // The setup page is for the admin only; the integration user never
    // opens it.
    try {
      if (installerId != null) {
        assignPermissionSet(
          findPackagePermissionSetId(setupPermSetName),
          new Set<Id>{ installerId }
        );
      }
    } catch (Exception e) {
      recordException('Assign ' + setupPermSetName, e);
    }

    try {
      Boolean hasUecAccess =
        packagePermSetId != null && permissionSetHasUecAccess(packagePermSetId);

      if (!hasUecAccess) {
        Id fallbackId = ensureFallbackPermissionSet();
        if (fallbackId != null) {
          assignPermissionSet(fallbackId, userIds);
        }
      }
    } catch (Exception e) {
      recordException('Ensure ' + UEC_SOBJECT + ' access', e);
    }

    reportProblems(installerId);
  }

  @TestVisible
  private void recordException(String step, Exception e) {
    problems.add(
      step +
        ' failed: ' +
        e.getTypeName() +
        ': ' +
        e.getMessage() +
        '\n' +
        e.getStackTraceString()
    );
  }

  private void recordSaveErrors(
    String action,
    List<Database.SaveResult> results
  ) {
    for (Database.SaveResult result : results) {
      for (Database.Error error : result.getErrors()) {
        problems.add(
          action +
            ' failed: ' +
            error.getStatusCode() +
            ': ' +
            error.getMessage()
        );
      }
    }
  }

  /**
   * Emails any problems to the installer. Sending is best effort: the
   * install must not fail because the report couldn't be sent.
   */
  @TestVisible
  private void reportProblems(Id installerId) {
    if (problems.isEmpty() || installerId == null) {
      return;
    }
    try {
      User installer = [
        SELECT Email
        FROM User
        WHERE Id = :installerId
        WITH SYSTEM_MODE
      ];
      Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
      mail.setToAddresses(new List<String>{ installer.Email });
      mail.setSenderDisplayName('GitHub MCP package');
      mail.setSubject(
        'GitHub MCP post-install: ' + problems.size() + ' problem(s) found'
      );
      mail.setPlainTextBody(
        'The GitHub MCP package installed, but the post-install script ' +
          'hit the problems below in org ' +
          UserInfo.getOrganizationId() +
          '. Open the GitHub MCP Setup tab to see which permissions are ' +
          'still missing.\n\n' +
          String.join(problems, '\n\n')
      );
      Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'GitHub MCP post-install report not sent: ' + e.getMessage()
      );
    }
  }

  @TestVisible
  private Set<Id> collectTargetUsers(Id installerId) {
    Set<Id> users = new Set<Id>();
    if (installerId != null) {
      users.add(installerId);
    }
    Id integrationUserId = findPlatformIntegrationUserId();
    if (integrationUserId != null) {
      users.add(integrationUserId);
    }
    return users;
  }

  @TestVisible
  private Id findPlatformIntegrationUserId() {
    String expectedUsername = getIntegrationUsername();
    String expectedEmail = getIntegrationEmail();

    List<User> byUsername = [
      SELECT Id
      FROM User
      WHERE IsActive = TRUE AND Username = :expectedUsername
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!byUsername.isEmpty()) {
      return byUsername[0].Id;
    }

    List<User> byEmail = [
      SELECT Id
      FROM User
      WHERE IsActive = TRUE AND Email = :expectedEmail
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return byEmail.isEmpty() ? null : byEmail[0].Id;
  }

  @TestVisible
  private static String getIntegrationUsername() {
    if (integrationUsernameOverride != null) {
      return integrationUsernameOverride;
    }
    return INTEGRATION_USERNAME_PREFIX + getOrgId18Lower();
  }

  @TestVisible
  private static String getIntegrationEmail() {
    if (integrationEmailOverride != null) {
      return integrationEmailOverride;
    }
    return INTEGRATION_EMAIL_PREFIX + getOrgId18Lower();
  }

  @TestVisible
  private static String getOrgId18Lower() {
    // Casting through Id guarantees the 18-character form even if the
    // underlying API returned a 15-character id.
    Id orgId = UserInfo.getOrganizationId();
    return String.valueOf(orgId).toLowerCase();
  }

  @TestVisible
  private Id findPackagePermissionSetId(String developerName) {
    List<PermissionSet> sets = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = :developerName AND NamespacePrefix = :packageNamespace
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return sets.isEmpty() ? null : sets[0].Id;
  }

  @TestVisible
  private Id findPermissionSetIdByName(String developerName) {
    List<PermissionSet> sets = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = :developerName
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return sets.isEmpty() ? null : sets[0].Id;
  }

  @TestVisible
  private Boolean permissionSetHasUecAccess(Id permSetId) {
    List<ObjectPermissions> perms = [
      SELECT Id
      FROM ObjectPermissions
      WHERE
        ParentId = :permSetId
        AND SobjectType = :UEC_SOBJECT
        AND PermissionsRead = TRUE
        AND PermissionsEdit = TRUE
        AND PermissionsDelete = TRUE
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return !perms.isEmpty();
  }

  @TestVisible
  private Id ensureFallbackPermissionSet() {
    Id existingId = findPermissionSetIdByName(fallbackPermSetName);
    if (existingId != null) {
      if (!permissionSetHasUecAccess(existingId)) {
        grantUecAccess(existingId);
      }
      return existingId;
    }

    PermissionSet ps = new PermissionSet(
      Name = fallbackPermSetName,
      Label = fallbackPermSetLabel,
      Description = 'Auto-generated by the GitHub MCP post-install to ensure UserExternalCredential access when the packaged permission set is missing it.'
    );
    Database.SaveResult psResult = Database.insert(
      ps,
      false,
      AccessLevel.SYSTEM_MODE
    );
    if (!psResult.isSuccess()) {
      recordSaveErrors(
        'Create permission set ' + fallbackPermSetName,
        new List<Database.SaveResult>{ psResult }
      );
      return null;
    }

    grantUecAccess(ps.Id);
    return ps.Id;
  }

  /**
   * Grants the same `UserExternalCredential` access the packaged permission
   * set carries: Read, Edit, and Delete, but not Create. Updates the
   * existing object permission row if there is one, since a permission set
   * can hold only one row per object.
   */
  private void grantUecAccess(Id permSetId) {
    List<ObjectPermissions> existing = [
      SELECT Id
      FROM ObjectPermissions
      WHERE ParentId = :permSetId AND SobjectType = :UEC_SOBJECT
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    ObjectPermissions op = existing.isEmpty()
      ? new ObjectPermissions(ParentId = permSetId, SobjectType = UEC_SOBJECT)
      : existing[0];
    op.PermissionsRead = true;
    op.PermissionsCreate = false;
    op.PermissionsEdit = true;
    op.PermissionsDelete = true;
    op.PermissionsViewAllRecords = false;
    op.PermissionsModifyAllRecords = false;

    Database.SaveResult result = existing.isEmpty()
      ? Database.insert(op, false, AccessLevel.SYSTEM_MODE)
      : Database.update(op, false, AccessLevel.SYSTEM_MODE);
    recordSaveErrors(
      'Grant ' + UEC_SOBJECT + ' access on permission set ' + permSetId,
      new List<Database.SaveResult>{ result }
    );
  }

  @TestVisible
  private void assignPermissionSet(Id permSetId, Set<Id> userIds) {
    if (permSetId == null || userIds == null || userIds.isEmpty()) {
      return;
    }

    Set<Id> alreadyAssigned = new Set<Id>();
    for (PermissionSetAssignment psa : [
      SELECT AssigneeId
      FROM PermissionSetAssignment
      WHERE PermissionSetId = :permSetId AND AssigneeId IN :userIds
      WITH SYSTEM_MODE
    ]) {
      alreadyAssigned.add(psa.AssigneeId);
    }

    List<PermissionSetAssignment> toCreate = new List<PermissionSetAssignment>();
    for (Id uid : userIds) {
      if (!alreadyAssigned.contains(uid)) {
        toCreate.add(
          new PermissionSetAssignment(
            AssigneeId = uid,
            PermissionSetId = permSetId
          )
        );
      }
    }

    if (!toCreate.isEmpty()) {
      recordSaveErrors(
        'Assign permission set ' + permSetId,
        Database.insert(toCreate, false, AccessLevel.SYSTEM_MODE)
      );
    }
  }
}
