####################################################################################################################################
# Mock Stanza Module Tests
####################################################################################################################################
package pgBackRestTest::Module::Mock::MockStanzaTest;
use parent 'pgBackRestTest::Env::HostEnvTest';

####################################################################################################################################
# Perl includes
####################################################################################################################################
use strict;
use warnings FATAL => qw(all);
use Carp qw(confess);

use File::Basename qw(dirname);

use pgBackRest::Archive::Info;
use pgBackRest::Backup::Info;
use pgBackRest::Common::Exception;
use pgBackRest::Common::Ini;
use pgBackRest::Common::Log;
use pgBackRest::Common::Wait;
use pgBackRest::Config::Config;
use pgBackRest::DbVersion;
use pgBackRest::InfoCommon;
use pgBackRest::Manifest;
use pgBackRest::Storage::Base;
use pgBackRest::Storage::Helper;

use pgBackRestTest::Env::HostEnvTest;
use pgBackRestTest::Common::ExecuteTest;
use pgBackRestTest::Common::FileTest;
use pgBackRestTest::Common::RunTest;
use pgBackRestTest::Common::VmTest;

####################################################################################################################################
# run
####################################################################################################################################
sub run
{
    my $self = shift;

    # Archive and backup info file names
    my $strArchiveInfoFile = STORAGE_REPO_ARCHIVE . qw{/} . ARCHIVE_INFO_FILE;
    my $strArchiveInfoCopyFile = STORAGE_REPO_ARCHIVE . qw{/} . ARCHIVE_INFO_FILE . INI_COPY_EXT;
    my $strArchiveInfoOldFile = "${strArchiveInfoFile}.old";
    my $strArchiveInfoCopyOldFile = "${strArchiveInfoCopyFile}.old";

    my $strBackupInfoFile = STORAGE_REPO_BACKUP . qw{/} . FILE_BACKUP_INFO;
    my $strBackupInfoCopyFile = STORAGE_REPO_BACKUP . qw{/} . FILE_BACKUP_INFO . INI_COPY_EXT;
    my $strBackupInfoOldFile = "${strBackupInfoFile}.old";
    my $strBackupInfoCopyOldFile = "${strBackupInfoCopyFile}.old";

    foreach my $rhRun
    (
        {vm => VM1, remote => false, s3 => false, encrypt =>  true, compress =>  GZ},
        {vm => VM1, remote =>  true, s3 =>  true, encrypt => false, compress =>  GZ},
        {vm => VM2, remote => false, s3 =>  true, encrypt =>  true, compress =>  GZ},
        {vm => VM2, remote =>  true, s3 => false, encrypt => false, compress =>  GZ},
        {vm => VM3, remote => false, s3 => false, encrypt => false, compress =>  GZ},
        {vm => VM3, remote =>  true, s3 =>  true, encrypt =>  true, compress =>  GZ},
        {vm => VM4, remote => false, s3 =>  true, encrypt => false, compress =>  GZ},
        {vm => VM4, remote =>  true, s3 => false, encrypt =>  true, compress =>  GZ},
    )
    {
        # Only run tests for this vm
        next if ($rhRun->{vm} ne vmTest($self->vm()));

        # Increment the run, log, and decide whether this unit test should be run
        my $bRemote = $rhRun->{remote};
        my $bS3 = $rhRun->{s3};
        my $bEncrypt = $rhRun->{encrypt};
        my $strCompressType = $rhRun->{compress};

        # Increment the run, log, and decide whether this unit test should be run
        if (!$self->begin("remote ${bRemote}, s3 ${bS3}, enc ${bEncrypt}, cmp ${strCompressType}")) {next}

        # Create hosts, file object, and config
        my ($oHostDbMaster, $oHostDbStandby, $oHostBackup, $oHostS3) = $self->setup(
            true, $self->expect(), {bHostBackup => $bRemote, bS3 => $bS3, bRepoEncrypt => $bEncrypt,
            strCompressType => $strCompressType});

        # Create the stanza
        $oHostBackup->stanzaCreate('fail on missing control file', {iExpectedExitStatus => ERROR_FILE_MISSING,
            strOptionalParam => '--no-' . cfgOptionName(CFGOPT_ONLINE) . ' --' . cfgOptionName(CFGOPT_LOG_LEVEL_FILE) . '=info'});

        # Generate pg_control for stanza-create
        storageTest()->pathCreate(($oHostDbMaster->dbBasePath() . '/' . DB_PATH_GLOBAL), {bCreateParent => true});
        $self->controlGenerate($oHostDbMaster->dbBasePath(), PG_VERSION_93);

        # Fail stanza upgrade before stanza-create has been performed
        #--------------------------------------------------------------------------------------------------------------------------
        $oHostBackup->stanzaUpgrade('fail on stanza not initialized since archive.info is missing',
            {iExpectedExitStatus => ERROR_FILE_MISSING, strOptionalParam => '--no-' . cfgOptionName(CFGOPT_ONLINE)});

        # Create the stanza successfully without force
        #--------------------------------------------------------------------------------------------------------------------------
        $oHostBackup->stanzaCreate('successfully create the stanza', {strOptionalParam => '--no-' . cfgOptionName(CFGOPT_ONLINE)});

        # Rerun stanza-create and confirm it does not fail
        #--------------------------------------------------------------------------------------------------------------------------
        $oHostBackup->stanzaCreate(
            'do not fail on rerun of stanza-create - info files exist and DB section ok',
            {strOptionalParam => '--no-' . cfgOptionName(CFGOPT_ONLINE)});

        # Stanza Create fails when not using force - database mismatch with pg_control file
        #--------------------------------------------------------------------------------------------------------------------------
        # Change the database version by copying a new pg_control file
        $self->controlGenerate($oHostDbMaster->dbBasePath(), PG_VERSION_94);

        $oHostBackup->stanzaCreate('fail on database mismatch and warn force option deprecated',
            {iExpectedExitStatus => ERROR_FILE_INVALID, strOptionalParam => '--no-' . cfgOptionName(CFGOPT_ONLINE) .
            ' --' . cfgOptionName(CFGOPT_FORCE)});

        # Restore pg_control
        $self->controlGenerate($oHostDbMaster->dbBasePath(), PG_VERSION_93);

        # Perform a stanza upgrade which will indicate already up to date
        #--------------------------------------------------------------------------------------------------------------------------
        $oHostBackup->stanzaUpgrade('already up to date', {strOptionalParam => '--no-' . cfgOptionName(CFGOPT_ONLINE)});

        # Create the wal path
        my $strWalPath = $oHostDbMaster->dbBasePath() . '/pg_xlog';
        storageTest()->pathCreate("${strWalPath}/archive_status", {bCreateParent => true});

        # Stanza Create fails - missing archive.info from non-empty archive dir
        #--------------------------------------------------------------------------------------------------------------------------
        # Generate WAL then push to get valid archive data in the archive directory
        my $strArchiveFile = $self->walSegment(1, 1, 1);
        my $strSourceFile = $self->walGenerate($strWalPath, PG_VERSION_93, 1, $strArchiveFile);

        my $strCommand = $oHostDbMaster->backrestExe() . ' --config=' . $oHostDbMaster->backrestConfig() .
            ' --stanza=db archive-push';
        $oHostDbMaster->executeSimple($strCommand . " ${strSourceFile}", {oLogTest => $self->expect()});

        # With data existing in the archive dir, move the info files and confirm failure
        forceStorageMove(storageRepo(), $strArchiveInfoFile, $strArchiveInfoOldFile, {bRecurse => false});
        forceStorageMove(storageRepo(), $strArchiveInfoCopyFile, $strArchiveInfoCopyOldFile, {bRecurse => false});

        if (!$bEncrypt)
        {
            $oHostBackup->stanzaCreate('fail on archive info file missing from non-empty dir',
                {iExpectedExitStatus => ERROR_FILE_MISSING, strOptionalParam => '--no-' . cfgOptionName(CFGOPT_ONLINE)});
        }

        # Restore info files from copy
        forceStorageMove(storageRepo(), $strArchiveInfoOldFile, $strArchiveInfoFile, {bRecurse => false});
        forceStorageMove(storageRepo(), $strArchiveInfoCopyOldFile, $strArchiveInfoCopyFile, {bRecurse => false});

        # Just before upgrading push one last WAL on the old version to ensure it can be retrieved later
        #--------------------------------------------------------------------------------------------------------------------------
        $strArchiveFile = $self->walSegment(1, 1, 2);
        $strSourceFile = $self->walGenerate($strWalPath, PG_VERSION_93, 1, $strArchiveFile);
        $oHostDbMaster->executeSimple($strCommand . " ${strSourceFile}", {oLogTest => $self->expect()});

        # Fail on archive push due to mismatch of DB since stanza not upgraded
        #--------------------------------------------------------------------------------------------------------------------------
        my $strArchiveTestFile = $self->testPath() . '/test-wal';
        storageTest()->put($strArchiveTestFile, $self->walGenerateContent(PG_VERSION_94));

        # Upgrade the DB by copying new pg_control
        $self->controlGenerate($oHostDbMaster->dbBasePath(), PG_VERSION_94);
        forceStorageMode(storageTest(), $oHostDbMaster->dbBasePath() . '/' . DB_FILE_PGCONTROL, '600');

        # Fail on attempt to push an archive
        $oHostDbMaster->archivePush($strWalPath, $strArchiveTestFile, 1, ERROR_ARCHIVE_MISMATCH);

        # Perform a successful stanza upgrade noting additional history lines in info files for new version of the database
        #--------------------------------------------------------------------------------------------------------------------------
        #  Save a pre-upgrade copy of archive info fo testing db-id mismatch
        forceStorageMove(storageRepo(), $strArchiveInfoCopyFile, $strArchiveInfoCopyOldFile, {bRecurse => false});

        $oHostBackup->stanzaUpgrade('successful upgrade creates additional history', {strOptionalParam => '--no-' .
            cfgOptionName(CFGOPT_ONLINE)});

        # Make sure that WAL from the old version can still be retrieved
        #--------------------------------------------------------------------------------------------------------------------------
        # Generate the old pg_control so it looks like the original db has been restored
        $self->controlGenerate($oHostDbMaster->dbBasePath(), PG_VERSION_93);

        # Attempt to get the last archive log that was pushed to this repo
        $oHostDbMaster->executeSimple(
            $oHostDbMaster->backrestExe() . ' --config=' . $oHostDbMaster->backrestConfig() .
                " --stanza=db archive-get ${strArchiveFile} " . $oHostDbMaster->dbBasePath() . '/pg_xlog/RECOVERYXLOG',
            {oLogTest => $self->expect()});

        # Copy the new pg_control back so the tests can continue with the upgraded stanza
        $self->controlGenerate($oHostDbMaster->dbBasePath(), PG_VERSION_94);
        forceStorageMode(storageTest(), $oHostDbMaster->dbBasePath() . '/' . DB_FILE_PGCONTROL, '600');

        # After stanza upgrade, make sure archives are pushed to the new db verion-id directory (9.4-2)
        #--------------------------------------------------------------------------------------------------------------------------
        # Push a WAL segment so have a valid file in the latest DB archive dir only
        $oHostDbMaster->archivePush($strWalPath, $strArchiveTestFile, 1);
        $self->testResult(
            sub {storageRepo()->list(STORAGE_REPO_ARCHIVE . qw{/} . PG_VERSION_94 . '-2/0000000100000001')},
            '000000010000000100000001-' . $self->walGenerateContentChecksum(PG_VERSION_94) . ".${strCompressType}",
            'check that WAL is in the archive at -2');

        # Create the tablespace directory and perform a backup
        #--------------------------------------------------------------------------------------------------------------------------
        storageTest()->pathCreate($oHostDbMaster->dbBasePath() . '/' . DB_PATH_PGTBLSPC);
        $oHostBackup->backup(
            'full', 'create first full backup ',
            {strOptionalParam => '--repo1-retention-full=2 --no-' . cfgOptionName(CFGOPT_ONLINE)}, false);

        # Upgrade the stanza
        #--------------------------------------------------------------------------------------------------------------------------
        # Copy pg_control for 9.5
        $self->controlGenerate($oHostDbMaster->dbBasePath(), PG_VERSION_95);
        forceStorageMode(storageTest(), $oHostDbMaster->dbBasePath() . '/' . DB_FILE_PGCONTROL, '600');


        $oHostBackup->stanzaUpgrade('successfully upgrade', {strOptionalParam => '--no-' . cfgOptionName(CFGOPT_ONLINE)});

        # Copy archive.info and restore really old version
        forceStorageMove(storageRepo(), $strArchiveInfoFile, $strArchiveInfoOldFile, {bRecurse => false});
        forceStorageRemove(storageRepo(), $strArchiveInfoCopyFile, {bRecurse => false});
        forceStorageMove(storageRepo(), $strArchiveInfoCopyOldFile, $strArchiveInfoFile, {bRecurse => false});

        #  Confirm versions
        my $oArchiveInfo = new pgBackRest::Archive::Info(storageRepo()->pathGet('archive/' . $self->stanza()));
        my $oBackupInfo = new pgBackRest::Backup::Info(storageRepo()->pathGet('backup/' . $self->stanza()));
        $self->testResult(sub {$oArchiveInfo->test(INFO_ARCHIVE_SECTION_DB, INFO_ARCHIVE_KEY_DB_VERSION, undef,
            PG_VERSION_93)}, true, 'archive at old pg version');
        $self->testResult(sub {$oBackupInfo->test(INFO_BACKUP_SECTION_DB, INFO_BACKUP_KEY_DB_VERSION, undef,
            PG_VERSION_95)}, true, 'backup at new pg version');

        $oHostBackup->stanzaUpgrade(
            'upgrade fails with mismatched db-ids',
            {iExpectedExitStatus => ERROR_FILE_INVALID, strOptionalParam => '--no-' . cfgOptionName(CFGOPT_ONLINE)});

        # Restore archive.info
        forceStorageMove(storageRepo(), $strArchiveInfoOldFile, $strArchiveInfoFile, {bRecurse => false});

        # Push a WAL and create a backup in the new DB to confirm diff changed to full
        #--------------------------------------------------------------------------------------------------------------------------
        storageTest()->put($strArchiveTestFile, $self->walGenerateContent(PG_VERSION_95));
        $oHostDbMaster->archivePush($strWalPath, $strArchiveTestFile, 1);

        # Test backup is changed from type=DIFF to FULL (WARN message displayed)
        my $oExecuteBackup = $oHostBackup->backupBegin('diff', 'diff changed to full backup',
            {strOptionalParam => '--repo1-retention-full=2 --no-' . cfgOptionName(CFGOPT_ONLINE)});
        $oHostBackup->backupEnd('full', $oExecuteBackup, undef, false);

        # Delete the stanza
        #--------------------------------------------------------------------------------------------------------------------------
        $oHostBackup->stanzaDelete('fail on missing stop file', {iExpectedExitStatus => ERROR_FILE_MISSING});

        $oHostBackup->stop({strStanza => $self->stanza()});
        $oHostBackup->stanzaDelete('successfully delete the stanza');
    }
}

1;
