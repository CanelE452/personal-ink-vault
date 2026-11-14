"""Two parent regressions using real Windows files and fake Office/OS boundaries.

Version 3 preserves the original response injection and accepts dict or (body, rawSHA).
Profile ruling: blocking A's first move leaves normal flow usable. If A has
already moved but installing B is blocked, do not restore A inside the guard;
the unchanged product must reject the now-missing path and preserve foreign B.
A completed swap must still preserve B through the full context close.
Retained regressions1/2 and their original deletion RED are not modified.
Source regression suite: only this module's two methods are selected. Existing product and
fixture sources are imported without editing or discovering their test methods.
Root alone executes this script; this is not native Office/process acceptance.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parents[2]
OFFICE = PROJECT / 'windows' / 'office_engine'
sys.path.insert(0, str(OFFICE))
import test_embedded_stages as parent_fixtures

SCOPE = 'real Windows filesystem; actual child/parent phase code; fake Office/process OS boundaries'
FORGED = 'FORGED'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def publish_bytes(path, data):
    with Path(path).open('wb') as stream:
        if stream.write(data) != len(data):
            raise AssertionError('The controlled regression write was incomplete')
        stream.flush()
        os.fsync(stream.fileno())


def first_cell(snapshot):
    for slide in snapshot['slides']:
        for table in slide['presentationTables'] or []:
            if table['cells']:
                return table['cells'][0]
    raise AssertionError('The actual fixture must contain a native table cell')


def file_identity(path):
    value = Path(path).stat()
    return value.st_dev, value.st_ino


def under(path, root):
    path, root = Path(path).resolve(), Path(root).resolve(strict=True)
    if path == root or not path.is_relative_to(root):
        raise AssertionError('A controlled filesystem target escaped its own temporary directory')
    return path


def diagnostic(name, value):
    print(name + ' ' + json.dumps({'scope': SCOPE, **value}, ensure_ascii=False, sort_keys=True), flush=True)


class EmbeddedParentRegressionsTest(unittest.TestCase):
    def test_final_observe_response_object_is_bound_to_attested_response_bytes(self):
        self.assertEqual(os.name, 'nt', 'This regression requires real Windows filesystem behavior')
        fixture = parent_fixtures.EmbeddedStagesTest(methodName='runTest')
        with fixture.fixture() as state:
            real_wait = state.module._wait_owned
            real_response = state.stages._response
            real_shared_bytes = state.module._shared_bytes
            waited_observe = set()
            observation = dict(injected=False, waitFinishedBeforeInjection=False,
                completeBeforeInjection=False, realSharedBytesRead=False,
                originalSha256=None, forgedSha256=None, restoredSha256=None,
                proofResponseSha256=None, originalRestored=False,
                parsedForgedText=None, parsedReturnKind=None, parsedBoundSha256=None,
                forgedBoundShaVerified=False, returnedText=None, stageReturned=False,
                stageError=None)

            def wait_owned(owner, deadline):
                result = real_wait(owner, deadline)
                if owner.phase == 'observe':
                    self.assertTrue(owner.finished.is_set())
                    waited_observe.add(Path(owner.phase_root))
                return result

            def response(phase_root):
                phase_root = Path(phase_root)
                # Poll reads before _wait_owned returns remain entirely unchanged.
                if phase_root not in waited_observe or observation['injected']:
                    return real_response(phase_root)
                self.assertEqual(state.harness.processes[-1].phase, 'observe')
                self.assertTrue((phase_root / 'embedded-complete').is_file())
                response_path = phase_root / 'response.json'
                original = real_shared_bytes(response_path)
                original_value = json.loads(original)
                self.assertIs(original_value['ok'], True)
                self.assertEqual(original_value['result']['status'], 'observed')
                forged_value = copy.deepcopy(original_value)
                cell = first_cell(forged_value['result']['snapshot'])
                self.assertNotEqual(cell['text'], FORGED)
                cell['text'] = FORGED
                forged = (json.dumps(forged_value, ensure_ascii=False,
                    allow_nan=False, separators=(',', ':')) + '\n').encode('utf-8')
                self.assertNotEqual(original, forged)
                proof = json.loads(real_shared_bytes(phase_root / 'embedded-proof.json'))
                self.assertEqual(proof['responseSha256'], sha(original))
                self.assertEqual(proof['terminationResponseSha256'], sha(original))
                observation.update(injected=True, waitFinishedBeforeInjection=True,
                    completeBeforeInjection=True, originalSha256=sha(original),
                    forgedSha256=sha(forged), proofResponseSha256=proof['responseSha256'])
                try:
                    publish_bytes(response_path, forged)
                    self.assertEqual(real_shared_bytes(response_path), forged)
                    observation['realSharedBytesRead'] = True
                    parsed = real_response(phase_root)
                    if type(parsed) is tuple:
                        self.assertEqual(len(parsed), 2, 'The response tuple must retain its body/hash contract')
                        body, bound_sha = parsed
                        observation['parsedReturnKind'] = 'body-sha256-tuple'
                        observation['parsedBoundSha256'] = bound_sha
                        observation['forgedBoundShaVerified'] = bound_sha == sha(forged)
                        self.assertIs(type(bound_sha), str)
                        self.assertEqual(bound_sha, sha(forged),
                            'The tuple hash must attest the actual forged bytes read by the real reader')
                    else:
                        self.assertIs(type(parsed), dict, 'Only the old dict or new body/hash tuple is supported')
                        body = parsed
                        observation['parsedReturnKind'] = 'body-dict'
                    observation['parsedForgedText'] = first_cell(body['result']['snapshot'])['text']
                    self.assertEqual(observation['parsedForgedText'], FORGED)
                finally:
                    publish_bytes(response_path, original)
                    restored = real_shared_bytes(response_path)
                    observation['restoredSha256'] = sha(restored)
                    observation['originalRestored'] = restored == original
                    self.assertEqual(restored, original)
                return parsed

            with patch.object(state.module, '_wait_owned', side_effect=wait_owned), \
                    patch.object(state.stages, '_response', side_effect=response):
                fixture.drive(state)
            observation['stageReturned'] = state.result is not None
            observation['stageError'] = None if state.caught is None else dict(
                type=type(state.caught).__name__, message=str(state.caught)[:512])
            if state.result is not None:
                observation['returnedText'] = first_cell(state.result['snapshot'])['text']
            diagnostic('EMBEDDED_PARENT_FINAL_RESPONSE_SWAP', observation)
            self.assertTrue(observation['injected'], 'The final post-wait parsed read was never exercised')
            self.assertTrue(observation['waitFinishedBeforeInjection'])
            self.assertTrue(observation['completeBeforeInjection'])
            self.assertTrue(observation['realSharedBytesRead'])
            self.assertTrue(observation['originalRestored'])
            self.assertEqual(observation['restoredSha256'], observation['originalSha256'])
            self.assertEqual(observation['proofResponseSha256'], observation['originalSha256'])
            self.assertEqual(observation['parsedForgedText'], FORGED)
            if observation['parsedReturnKind'] == 'body-sha256-tuple':
                self.assertTrue(observation['forgedBoundShaVerified'])
                self.assertEqual(observation['parsedBoundSha256'], observation['forgedSha256'])
            else:
                self.assertEqual(observation['parsedReturnKind'], 'body-dict')
            self.assertNotEqual(observation['returnedText'], FORGED,
                'The parent returned forged native snapshot data under the original response proof/hash')

    def test_profile_mkdir_substitution_is_blocked_or_foreign_directory_is_preserved(self):
        self.assertEqual(os.name, 'nt', 'This regression requires real Windows filesystem behavior')
        fixture = parent_fixtures.EmbeddedStagesTest(methodName='runTest')
        with fixture.fixture(inspect_preview=False) as state:
            temporary = state.native.root.parent.resolve(strict=True)
            foreign = under(temporary / 'regression-foreign-profile', temporary)
            created_away = under(temporary / 'regression-created-profile-away', temporary)
            control_created = under(temporary / 'regression-control-created', temporary)
            control_away = under(temporary / 'regression-control-away', temporary)
            self.assertFalse(foreign.is_relative_to(state.directory.resolve()))
            for path in (foreign, created_away, control_created, control_away):
                self.assertFalse(os.path.lexists(path))
            foreign.mkdir()
            sentinel_name = 'foreign-sentinel.bin'
            sentinel_bytes = b'FOREIGN NORMAL DIRECTORY: PRESERVE THIS SENTINEL'
            publish_bytes(foreign / sentinel_name, sentinel_bytes)
            foreign_identity = file_identity(foreign)
            self.assertFalse(foreign.is_symlink())
            self.assertEqual(foreign.stat().st_dev, temporary.stat().st_dev)

            # The identical ordinary-directory rename sequence must work without
            # parent stage leases before a later sharing failure is meaningful.
            control_created.mkdir()
            control_identity = file_identity(control_created)
            control_created.rename(control_away)
            foreign.rename(control_created)
            self.assertEqual(file_identity(control_created), foreign_identity)
            self.assertEqual((control_created / sentinel_name).read_bytes(), sentinel_bytes)
            control_created.rename(foreign)
            control_away.rename(control_created)
            self.assertEqual(file_identity(control_created), control_identity)
            self.assertEqual(file_identity(foreign), foreign_identity)
            self.assertEqual((foreign / sentinel_name).read_bytes(), sentinel_bytes)
            control_created.rmdir()

            observation = dict(unleasedRenameControl=True, hookAttempted=False,
                attemptedAt=None, blockedAt=None, blockedWinError=None,
                blockedError=None, createdMovedAway=False, swapCompleted=False,
                partialMutation=False, expectedStageOutcome='pending-actual-attempt',
                restorationAttemptedInsideGuard=False, hookReturnedAfterInstallBlock=False,
                createdPathMissingAfterBlockedInstall=False, createdAwayIdentityPreserved=False,
                partialMutationRefused=False,
                createdIdentity=None, foreignIdentity=list(foreign_identity),
                installedIdentity=None, identityChanged=False,
                contextClosed=False, stageReturned=False, stageError=None,
                foreignIdentityPreserved=False, foreignBytesPreserved=False,
                foreignEntriesAfter=None)
            real_mkdir = Path.mkdir
            main_thread = threading.get_ident()
            target_profile = None

            def mkdir(path, *arguments, **keywords):
                nonlocal target_profile
                result = real_mkdir(path, *arguments, **keywords)
                path = Path(path)
                selected = (threading.get_ident() == main_thread and not observation['hookAttempted'] and
                    path.name == 'profile' and path.parent.parent.name == 'phases' and
                    path.parent.parent.parent == state.directory)
                if not selected:
                    return result
                target_profile = under(path, temporary)
                self.assertTrue(target_profile.is_relative_to(state.directory.resolve(strict=True)))
                self.assertFalse(target_profile.is_symlink())
                original_identity = file_identity(target_profile)
                observation.update(hookAttempted=True,
                    attemptedAt='after-real-mkdir-before-parent-first-stat',
                    createdIdentity=list(original_identity))
                try:
                    target_profile.rename(created_away)
                    observation['createdMovedAway'] = True
                except OSError as error:
                    observation.update(blockedAt='move-created-away',
                        expectedStageOutcome='normal-success-original-path-unchanged',
                        blockedWinError=getattr(error, 'winerror', None),
                        blockedError=dict(type=type(error).__name__, errno=error.errno))
                    self.assertEqual(file_identity(target_profile), original_identity)
                    self.assertEqual(file_identity(foreign), foreign_identity)
                    self.assertEqual((foreign / sentinel_name).read_bytes(), sentinel_bytes)
                    return result
                try:
                    foreign.rename(target_profile)
                except OSError as error:
                    observation.update(blockedAt='install-foreign-directory',
                        partialMutation=True, expectedStageOutcome='fail-closed-after-partial-mutation',
                        blockedWinError=getattr(error, 'winerror', None),
                        blockedError=dict(type=type(error).__name__, errno=error.errno))
                    self.assertFalse(os.path.lexists(target_profile))
                    self.assertEqual(file_identity(created_away), original_identity)
                    self.assertEqual(file_identity(foreign), foreign_identity)
                    self.assertEqual((foreign / sentinel_name).read_bytes(), sentinel_bytes)
                    observation['createdPathMissingAfterBlockedInstall'] = True
                    observation['hookReturnedAfterInstallBlock'] = True
                    # Return without rollback while the product guard is held.
                    # The product's own next stat must reject the missing A path.
                    return result
                installed = file_identity(target_profile)
                observation.update(swapCompleted=True, installedIdentity=list(installed),
                    identityChanged=installed != original_identity,
                    expectedStageOutcome='foreign-directory-survives-context-close')
                self.assertEqual(installed, foreign_identity)
                self.assertNotEqual(installed, original_identity)
                self.assertEqual((target_profile / sentinel_name).read_bytes(), sentinel_bytes)
                return result

            with patch.object(Path, 'mkdir', new=mkdir):
                fixture.drive(state)
            observation['contextClosed'] = state.stages._closed
            observation['stageReturned'] = state.result is not None
            observation['stageError'] = None if state.caught is None else dict(
                type=type(state.caught).__name__, message=str(state.caught)[:512])
            if observation['createdMovedAway'] and created_away.is_dir():
                observation['createdAwayIdentityPreserved'] = (
                    list(file_identity(created_away)) == observation['createdIdentity'])
            if observation['partialMutation']:
                observation['partialMutationRefused'] = state.caught is not None and state.result is None
                observation['createdPathMissingAfterBlockedInstall'] = not os.path.lexists(target_profile)
            # No restoration is needed: A is our own empty directory in fixture temp.
            locations = [foreign]
            if target_profile is not None:
                locations.append(target_profile)
            for location in locations:
                if location.is_dir() and file_identity(location) == foreign_identity:
                    observation['foreignIdentityPreserved'] = True
                    observation['foreignEntriesAfter'] = sorted(item.name for item in location.iterdir())
                    sentinel = location / sentinel_name
                    observation['foreignBytesPreserved'] = sentinel.is_file() and sentinel.read_bytes() == sentinel_bytes
            diagnostic('EMBEDDED_PARENT_PROFILE_DIRECTORY_SWAP', observation)
            self.assertTrue(observation['unleasedRenameControl'])
            self.assertTrue(observation['hookAttempted'], 'The actual post-mkdir boundary was never exercised')
            self.assertTrue(observation['contextClosed'], 'The entire stage context must close before judging cleanup')
            if observation['swapCompleted']:
                self.assertTrue(observation['identityChanged'])
            else:
                self.assertIsNotNone(observation['blockedAt'])
                self.assertIsNotNone(observation['blockedError'])
                self.assertEqual(file_identity(foreign), foreign_identity)
                self.assertEqual((foreign / sentinel_name).read_bytes(), sentinel_bytes)
                if observation['blockedAt'] == 'install-foreign-directory':
                    self.assertTrue(observation['createdMovedAway'])
                    self.assertTrue(observation['partialMutation'])
                    self.assertTrue(observation['hookReturnedAfterInstallBlock'],
                        'The hook itself failed before returning control to the product')
                    self.assertTrue(observation['createdAwayIdentityPreserved'])
                    self.assertTrue(observation['createdPathMissingAfterBlockedInstall'])
                    self.assertTrue(observation['partialMutationRefused'])
                    self.assertIsNotNone(state.caught,
                        'Removing A before B installation is blocked must fail closed')
                    self.assertIsNone(state.result)
                else:
                    self.assertEqual(observation['blockedAt'], 'move-created-away')
                    self.assertFalse(observation['createdMovedAway'])
                    self.assertFalse(observation['partialMutation'])
                    self.assertIsNone(state.caught,
                        'Blocking the first move must leave the unchanged normal flow usable')
            self.assertTrue(observation['foreignIdentityPreserved'] and observation['foreignBytesPreserved'],
                'Success/context cleanup removed the substituted foreign normal directory or its sentinel')


if __name__ == '__main__':
    diagnostic('EMBEDDED_PARENT_REGRESSIONS_SCOPE', dict(
        parentSha256=sha((OFFICE / 'office_embedded_stages.py').read_bytes()),
        childSha256=sha((OFFICE / 'office_embedded_bootstrap.py').read_bytes()),
        fixtureSha256=sha((OFFICE / 'test_embedded_stages.py').read_bytes()),
        selectedTestCount=2, nativeOfficeAcceptance=False))
    names = (
        'test_final_observe_response_object_is_bound_to_attested_response_bytes',
        'test_profile_mkdir_substitution_is_blocked_or_foreign_directory_is_preserved',
    )
    suite = unittest.TestSuite(EmbeddedParentRegressionsTest(name) for name in names)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
