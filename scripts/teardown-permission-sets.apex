/**
 * Removes the GitHub MCP package's permission set footprint from a
 * subscriber org, so the package can be uninstalled and reinstalled from a
 * clean starting point.
 *
 *   1. Deletes every assignment of the packaged permission sets (namespace
 *      `mvpbo3`: GitHub_Perm_Set, GitHub_MCP_Setup). Managed permission
 *      sets can't be deleted; uninstalling the package removes them.
 *   2. Deletes every assignment of the unmanaged permission sets whose API
 *      name matches UNMANAGED_NAME_PATTERNS. These include the post-install's
 *      fallback set (GitHub_MCP_UEC_Access), the GitHub_Perm_Set that Setup
 *      generates when an MCP server is registered by hand, and test sets
 *      such as github2.
 *   3. Removes all of those permission sets, managed and unmanaged, from any
 *      permission set group. A packaged permission set in a group blocks
 *      uninstall.
 *   4. Deletes the matched unmanaged permission sets.
 *
 * DRY RUN BY DEFAULT. With DRY_RUN = true the script runs every delete, reports
 * the results (including any errors), and then rolls everything back. Check
 * the "Unmanaged permission sets" list in the output, then set
 * DRY_RUN = false and run it again to commit.
 *
 * Run as a System Administrator:
 *   sf apex run --file scripts/teardown-permission-sets.apex --target-org <alias>
 * The report is in the debug log; filter for lines containing "TEARDOWN |".
 *
 * Not touched: users' stored GitHub tokens (UserExternalCredential), the
 * External Auth Identity Provider's client credentials, and the package
 * itself. Uninstall the package after this script commits.
 */

// ---- Configuration --------------------------------------------------------

// true: run every step, report the results, then roll everything back.
Boolean DRY_RUN = true;

// Namespace of the managed package.
String PACKAGE_NAMESPACE = 'mvpbo3';

// API names of unmanaged permission sets to delete. Matched with SOQL LIKE:
// case-insensitive, and % is a wildcard. Profile-owned and permission set
// group-owned permission sets are never matched.
List<String> UNMANAGED_NAME_PATTERNS = new List<String>{ 'GitHub%' };

// ---- Helpers --------------------------------------------------------------

void say(String message) {
  System.debug(LoggingLevel.ERROR, 'TEARDOWN | ' + message);
}

/** Deletes the records with partial success and reports each one. Returns the failure count. */
Integer deleteRecords(String step, Map<Id, String> labelsById) {
  if (labelsById.isEmpty()) {
    say(step + ': nothing to delete');
    return 0;
  }
  List<Id> ids = new List<Id>(labelsById.keySet());
  List<Database.DeleteResult> results = Database.delete(ids, false);
  Integer failures = 0;
  for (Integer i = 0; i < results.size(); i++) {
    if (results[i].isSuccess()) {
      say('  deleted ' + labelsById.get(ids[i]));
    } else {
      failures++;
      Database.Error error = results[i].getErrors()[0];
      say(
        '  FAILED ' +
          labelsById.get(ids[i]) +
          ': ' +
          error.getStatusCode() +
          ': ' +
          error.getMessage()
      );
    }
  }
  say(
    step + ': ' + (ids.size() - failures) + ' deleted, ' + failures + ' failed'
  );
  return failures;
}

// ---- Find -----------------------------------------------------------------

say(
  (DRY_RUN ? 'DRY RUN (all changes roll back)' : 'LIVE RUN') +
    ' in org ' +
    UserInfo.getOrganizationId() +
    ' as ' +
    UserInfo.getUserName()
);

List<PermissionSet> packagedSets = [
  SELECT Id, Name, Label
  FROM PermissionSet
  WHERE NamespacePrefix = :PACKAGE_NAMESPACE AND IsOwnedByProfile = FALSE
  ORDER BY Name
];

List<PermissionSet> unmanagedSets = [
  SELECT Id, Name, Label, CreatedBy.Username, CreatedDate
  FROM PermissionSet
  WHERE
    NamespacePrefix = NULL
    AND IsCustom = TRUE
    AND IsOwnedByProfile = FALSE
    AND PermissionSetGroupId = NULL
    AND Name LIKE :UNMANAGED_NAME_PATTERNS
  ORDER BY Name
];

say('Packaged permission sets (assignments removed, sets kept):');
for (PermissionSet ps : packagedSets) {
  say('  ' + PACKAGE_NAMESPACE + '__' + ps.Name + ' (' + ps.Label + ')');
}
if (packagedSets.isEmpty()) {
  say('  none. Is the package installed?');
}

say('Unmanaged permission sets (assignments removed, sets deleted):');
for (PermissionSet ps : unmanagedSets) {
  say(
    '  ' +
      ps.Name +
      ' (' +
      ps.Label +
      '), created ' +
      ps.CreatedDate.format('yyyy-MM-dd') +
      ' by ' +
      ps.CreatedBy.Username
  );
}
if (unmanagedSets.isEmpty()) {
  say('  none');
}

Set<Id> allSetIds = new Map<Id, PermissionSet>(packagedSets).keySet().clone();
Set<Id> unmanagedSetIds = new Map<Id, PermissionSet>(unmanagedSets).keySet();
allSetIds.addAll(unmanagedSetIds);

Map<Id, String> assignments = new Map<Id, String>();
for (PermissionSetAssignment psa : [
  SELECT Id, Assignee.Username, PermissionSet.Name
  FROM PermissionSetAssignment
  WHERE PermissionSetId IN :allSetIds
  ORDER BY PermissionSet.Name, Assignee.Username
]) {
  assignments.put(
    psa.Id,
    psa.PermissionSet.Name + ' -> ' + psa.Assignee.Username
  );
}

Map<Id, String> groupComponents = new Map<Id, String>();
for (PermissionSetGroupComponent component : [
  SELECT Id, PermissionSet.Name, PermissionSetGroup.DeveloperName
  FROM PermissionSetGroupComponent
  WHERE PermissionSetId IN :allSetIds
]) {
  groupComponents.put(
    component.Id,
    component.PermissionSet.Name +
      ' in group ' +
      component.PermissionSetGroup.DeveloperName
  );
}

Map<Id, String> setsToDelete = new Map<Id, String>();
for (PermissionSet ps : unmanagedSets) {
  setsToDelete.put(ps.Id, ps.Name);
}

// ---- Delete ---------------------------------------------------------------

// Order matters: a permission set can't be deleted while it's assigned or
// in a group.
Savepoint savepoint = Database.setSavepoint();
Integer failures = 0;
failures += deleteRecords('Permission set assignments', assignments);
failures += deleteRecords('Permission set group components', groupComponents);
failures += deleteRecords('Unmanaged permission sets', setsToDelete);

if (DRY_RUN) {
  Database.rollback(savepoint);
  say(
    'DRY RUN complete, everything rolled back. ' +
      failures +
      ' failure(s). Set DRY_RUN = false to commit.'
  );
} else {
  say(
    'LIVE RUN complete. ' +
      failures +
      ' failure(s).' +
      (failures > 0 ? ' Fix the failures above and run again.' : '')
  );
}
