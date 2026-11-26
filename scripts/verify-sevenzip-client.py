#!/usr/bin/env python3
"""Require the real native SDK/Swift client tests without silently skipping fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
from sevenzip_fixture import empty_files

TESTS = [
    'archiveCapabilityMatrixAdvertisesOnlyVerifiedProviderFeatures',
    'archiveEditPreservesEmptyEncrypted7zHeaderAndRejectsStaleSelection',
    'archiveEditUnicodeZIPLongPasswordsAndNormalizationRemainExact',
    'archiveEditTransactionCancellationBeforeSwapPreservesBothFiles',
    'archiveEditTransactionPublishesBacksUpAndUndoesWithMetadata',
    'archiveEditTransactionPreservesExternalChangesAndBrokenRecords',
    'archiveEditTransactionSerializesAndPreservesUnpublishedCandidate',
    'archiveEditTransactionRecoversPublishAndUndoProcessInterruptions',
    'archiveEditTransactionZIPAndEncrypted7zRoundTrip',
    'archiveEditVerificationKeepsUnicodeZIPMetadataAndAddsEncryptedData',
    'archiveEditVerificationRejectsChangedCandidateAndSource',
    'archiveEditPlanExpandsDirectoriesAndRejectsConflicts',
    'archiveEditCandidateUsesSandboxedClientAndPreservesOriginal',
    'archiveEditCandidateRejectsLinksAndUnsafePlansWithoutChangingSource',
    'sevenZipSDKLargePagedListing', 'sevenZipSDKRejectsMalformedListingPages',
    'sevenZipCreationUploadRejectsIncorrectAcknowledgments',
    'sevenZipSDKBundleWorkerPolicyRejectsExpandedAuthority',
    'sevenZipSDKRestoresFileAndDirectoryTimesAndPermissions', 'sevenZipSDKRestrictiveDirectoryMetadataFinishesAfterChildren',
    'sevenZipSDKRejectsMalformedMetadataBeforeStaging',
    'sevenZipSDKPublishedDirectoryTimeChangeIsPreserved',
    'sevenZipSDKUnrepresentableTimeFailsAndPreservesRestrictedRecovery',
    'sevenZipSDKMemoryBudgetKillsAndReapsWithoutPublishing', 'sevenZipSDKRejectsZeroMemoryBudgetBeforeLaunching',
    'sevenZipCreationBrokerRejectsInvalidAndTruncatedRequests',
    'sevenZipCreationBrokerKeepsPlannedIdentityAndReadOnlyAccess', 'sevenZipSDKCreationBrokerManyInputsAndPreflightPreserveSources',
    'sevenZipReadBrokerPinsDirectoryAndRejectsChangedNames', 'sevenZipSDKReadBrokerHandlesSymlinkAndSearchOnlyDirectory',
    'sevenZipSplitPreferencesPersistAndImportTransactionally', 'sevenZipSplitHistoryPreservesInvalidAndOfflineRecords',
    'sevenZipSplitFrameValidationAndForeignStagingPreservation',
    'sevenZipSDKSplitCreationAndCommittedJournal', 'sevenZipSDKSplitConflictsChangesAndCancellationPreserveData',
    'sevenZipSDKSplitProcessRestartRecoveryAndAmbiguousIntent',
    'archiveExtractionPlacementMatchesSmartTopLevelRules',
    'sevenZipVolumeNamesDetectionAndSelectionNormalization', 'sevenZipSDKSplitVolumesRoundTripFromAnyPartAndAcrossTinyHeaders',
    'sevenZipSDKSplitMissingTruncatedAndLinkedPartsNeverPublish',
    'sevenZipSDKAdvancedOptionsChangeDictionaryAndRestorePayload', 'sevenZipOptionsAndCreationFormatPersistAndImportTransactionally',
    'sevenZipMemoryEstimateHandlesStoreAndMaximumChoices',
    'sevenZipSDKCreationLevelsPasswordAndIndependentExtraction', 'sevenZipSDKCreationPlanRejectsLinksAndDuplicatePaths',
    'sevenZipSDKCreationSourceChangeAndDestinationRacePreserveData', 'sevenZipSDKCreationCancellationBeforePublicationDiscardsOutput',
    'sevenZipSDKFramedClientRejectsMalformedReplies', 'sevenZipSDKFragmentedReplyAndClose',
    'sevenZipSDKEOFOnDiagnosticPipeIsNotDiagnosticData',
    'sevenZipSDKTimeoutAndCancellationReapOwnedChild', 'sevenZipSDKValidatesPathsBeforeStaging',
    'sevenZipSDKEncryptedRoundTripAndFailureStaging', 'sevenZipSDKCorruptionAndLinksNeverPublish',
    'sevenZipSDKPublicationConflictAndForeignStagingPreservation', 'sevenZipSDKCancellationBeforePublicationDiscardsStaging',
    'sevenZipSDKBundleManifestRejectsUntrustedMetadata', 'sevenZipSDKBundleRejectsMissingLinksAndNonregularManifest',
    'sevenZipSDKBundleCancellationAndInvalidTimeout',
    'sevenZipSDKBundleDeveloperIDRequirementRejectsInvalidTeam',
    'sevenZipSDKBundleBindsExecutingHostIdentity',
    'sevenZipSDKExistingDirectoryExtractionPreservesUnrelatedItems', 'sevenZipSDKExistingDirectoryConflictRollsBackOwnedPublication',
    'sevenZipSDKExistingDirectoryChangedPublicationIsPreserved', 'sevenZipSDKExistingDirectoryCancellationRollsBackPublication',
]
BUNDLE_TESTS = ['sevenZipSDKBundleRejectsResignedExpandedWorkerAuthority', 'sevenZipSDKBundleResolutionAndUse', 'sevenZipSDKBundleRejectsResealedHashMismatch',
                'sevenZipSDKBundleRejectsAdhocStableAndWrongIdentity', 'sevenZipSDKBundleRejectsResealedSourcePinAndExtraFile',
                'sevenZipSDKBundlePinsSelectedRevisionAcrossResigning']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--bundle-manifest', type=Path)
    parser.add_argument('--app', type=Path, help='Also require signed app resolution and tampering tests')
    parser.add_argument('--probe', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, FILES_TEST_SEVENZIP_WORKER=str(args.worker.resolve()),
                       FILES_TEST_SEVENZIP_REFERENCE=str(args.reference.resolve()))
    large = args.output / 'large-list.7z'
    empty_files(large, ('entry-' + str(index) + '-' + 'a' * 80 for index in range(35000)))
    subprocess.run([str(args.reference), 't', str(large)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    environment['FILES_TEST_SEVENZIP_LARGE_LIST'] = str(large.resolve())
    if args.library: environment['FILES_TEST_SEVENZIP_LIBRARY'] = str(args.library.resolve())
    else: environment.pop('FILES_TEST_SEVENZIP_LIBRARY', None)
    if args.app: environment['FILES_TEST_SEVENZIP_APP_BUNDLE'] = str(args.app.resolve())
    else: environment.pop('FILES_TEST_SEVENZIP_APP_BUNDLE', None)
    probe = args.probe or Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], text=True).strip()) / 'FilesSplitProbe'
    if not probe.is_file(): raise RuntimeError('Missing process-restart probe; build test products first')
    environment['FILES_TEST_SPLIT_PROBE'] = str(probe.resolve())
    requested_tests = TESTS + (BUNDLE_TESTS if args.app else [])
    test_filter = '(' + '|'.join(re.escape(name) for name in requested_tests) + ')'
    timed_out = False
    # SwiftPM warnings may arrive in the middle of a Swift Testing test-name write.
    # Keep the streams separate so evidence matching does not lose a passed test.
    with (args.output / 'run.log').open('wb') as log, (args.output / 'stderr.log').open('wb') as diagnostics:
        process = subprocess.Popen(['swift', 'test', '--skip-build', '--disable-xctest', '--no-parallel', '--filter', test_filter],
                                   env=environment, stdout=log, stderr=diagnostics, start_new_session=True)
        try: process.wait(timeout=120)
        except subprocess.TimeoutExpired:
            timed_out = True
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
    log_path = args.output / 'run.log'
    text = log_path.read_text(errors='replace') if log_path.stat().st_size <= 8 * 1024 * 1024 else ''
    observed = {name: bool(re.search(r'Test ' + re.escape(name) + r'\(\) passed after', text)) for name in requested_tests}
    passed = process.returncode == 0 and not timed_out and all(observed.values()) and 'skipped' not in text.lower()
    repo = Path(__file__).resolve().parent.parent
    sources = ['Sources/FilesCore/ArchiveEditSourceVersion.swift', 'Sources/FilesCore/ArchiveEditTransaction.swift', 'Sources/FilesCore/ArchiveEditCandidate.swift', 'Sources/FilesCore/ArchiveEditPlan.swift', 'Sources/FilesCore/SevenZipReadSource.swift', 'Sources/FilesCore/ArchiveSplitSize.swift', 'Sources/FilesCore/SevenZipSplitJournalSummary.swift', 'Sources/FilesCore/SevenZipSplitStaging.swift', 'Tools/SplitCreationProbe/main.swift', 'Package.swift', 'Sources/FilesCore/SevenZipVolumes.swift', 'Sources/FilesCore/SevenZipCompressionOptions.swift', 'Sources/FilesCore/BrowserPreferences.swift', 'Sources/FilesCore/SevenZipCreationPlan.swift', 'Sources/FilesCore/SevenZipArchiveProvider.swift', 'Sources/FilesCore/SevenZipBundledBackend.swift',
               'Tests/FilesCoreTests/SevenZipArchiveProviderTests.swift', 'Tests/FilesCoreTests/SevenZipBundledBackendTests.swift']
    result = dict(passed=passed, exitCode=process.returncode, timedOut=timed_out, tests=observed,
                  sourcesSHA256={name: hashlib.sha256((repo / name).read_bytes()).hexdigest() for name in sources},
                  workerManifest=json.loads((args.bundle_manifest or args.worker.parent / 'manifest.json').read_text()),
                  referenceManifest=json.loads((args.reference.parent / 'manifest.json').read_text()),
                  productUIIntegration=False)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(passed=passed, tests=observed), indent=2))
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__': main()
