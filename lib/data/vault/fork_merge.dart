import 'package:ink_vault_core/ink_vault_core.dart';

/// Whether this device writes the merge of [heads] back as one revision,
/// as the library marks and the planner do when a read finds a fork (설계
/// 13절: two heads merge on read; the next write lists both as parents).
///
/// Two devices that read the same fork at once both write a merge, which
/// makes a new fork of two merges with the same parents. That one is left to
/// the device with the smallest id among its writers, so the devices never
/// keep merging each other's merges.
bool writesMergeBack(List<RevisionRecord> heads, String deviceId) {
  if (heads.length < 2) return false;
  final parents = heads.first.parentRevisionIds.toSet();
  final sameMerges =
      parents.length > 1 &&
      heads.every(
        (head) =>
            head.parentRevisionIds.length == parents.length &&
            parents.containsAll(head.parentRevisionIds),
      );
  if (!sameMerges) return true;
  final writers = [for (final head in heads) head.deviceId]..sort();
  return writers.first == deviceId;
}
