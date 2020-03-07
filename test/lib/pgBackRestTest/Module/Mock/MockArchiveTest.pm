####################################################################################################################################
# Mock Archive Tests
####################################################################################################################################
package pgBackRestTest::Module::Mock::MockArchiveTest;
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
use pgBackRest::DbVersion;
use pgBackRest::Common::Exception;
use pgBackRest::Common::Ini;
use pgBackRest::Common::Log;
use pgBackRest::Common::Wait;
use pgBackRest::Config::Config;
use pgBackRest::Manifest;
use pgBackRest::Protocol::Storage::Helper;

use pgBackRestTest::Env::HostEnvTest;
use pgBackRestTest::Common::ExecuteTest;
use pgBackRestTest::Common::RunTest;
use pgBackRestTest::Common::VmTest;

####################################################################################################################################
# archiveCheck
#
# Check that a WAL segment is present in the repository.
####################################################################################################################################
sub archiveCheck
{
    my $self = shift;
    my $strArchiveFile = shift;
    my $strArchiveChecksum = shift;
    my $strCompressType = shift;
    my $strSpoolPath = shift;

    # Build the archive name to check for at the destination
    my $strArchiveCheck = PG_VERSION_94 . "-1/${strArchiveFile}-${strArchiveChecksum}";

    if (defined($strCompressType))
    {
        $strArchiveCheck .= ".${strCompressType}";
    }

    my $oWait = waitInit(5);
    my $bFound = false;

    do
    {
        $bFound = storageRepo()->exists(STORAGE_REPO_ARCHIVE . "/${strArchiveCheck}");
    }
    while (!$bFound && waitMore($oWait));

    if (!$bFound)
    {
        confess 'unable to find ' . storageRepo()->pathGet(STORAGE_REPO_ARCHIVE . "/${strArchiveCheck}");
    }

    if (defined($strSpoolPath))
    {
        storageTest()->remove("${strSpoolPath}/archive/" . $self->stanza() . "/out/${strArchiveFile}.ok");
    }
}

####################################################################################################################################
# run
####################################################################################################################################
sub run
{
    my $self = shift;

    my $strArchiveChecksum = $self->walGenerateContentChecksum(PG_VERSION_94, {iSourceNo => 2});

    foreach my $rhRun
    (
        {vm => VM1, remote => false, s3 => false, encrypt => false, compress =>  GZ},
        {vm => VM1, remote =>  true, s3 =>  true, encrypt =>  true, compress =>  GZ},
        {vm => VM2, remote => false, s3 =>  true, encrypt => false, compress =>  GZ},
        {vm => VM2, remote =>  true, s3 => false, encrypt =>  true, compress =>  GZ},
        {vm => VM3, remote => false, s3 => false, encrypt =>  true, compress =>  GZ},
        {vm => VM3, remote =>  true, s3 =>  true, encrypt => false, compress =>  GZ},
        {vm => VM4, remote => false, s3 =>  true, encrypt =>  true, compress =>  GZ},
        {vm => VM4, remote =>  true, s3 => false, encrypt => false, compress =>  GZ},
    )
    {
        # Only run tests for this vm
        next if ($rhRun->{vm} ne vmTest($self->vm()));

        # Increment the run, log, and decide whether this unit test should be run
        my $bRemote = $rhRun->{remote};
        my $bS3 = $rhRun->{s3};
        my $bEncrypt = $rhRun->{encrypt};
        my $strCompressType = $rhRun->{compress};

        if (!$self->begin("rmt ${bRemote}, s3 ${bS3}, enc ${bEncrypt}, cmp ${strCompressType}")) {next}

        # Create hosts, file object, and config
        my ($oHostDbMaster, $oHostDbStandby, $oHostBackup) = $self->setup(
            true, $self->expect(), {bHostBackup => $bRemote, bS3 => $bS3, bRepoEncrypt => $bEncrypt, strCompressType => NONE});

        # Reduce console logging to detail
        $oHostDbMaster->configUpdate({&CFGDEF_SECTION_GLOBAL => {cfgOptionName(CFGOPT_LOG_LEVEL_CONSOLE) => lc(DETAIL)}});

        # Create the wal path
        my $strWalPath = $oHostDbMaster->dbBasePath() . '/pg_xlog';
        storageTest()->pathCreate($strWalPath, {bCreateParent => true});

        # Generate pg_control for stanza-create
        storageTest()->pathCreate($oHostDbMaster->dbBasePath() . '/' . DB_PATH_GLOBAL, {bCreateParent => true});
        $self->controlGenerate($oHostDbMaster->dbBasePath(), PG_VERSION_94);

        # Create archive-push command
        my $strCommandPush =
            $oHostDbMaster->backrestExe() . ' --config=' . $oHostDbMaster->backrestConfig() . ' --stanza=' . $self->stanza() .
            ' ' . cfgCommandName(CFGCMD_ARCHIVE_PUSH);

        my $strCommandGet =
            $oHostDbMaster->backrestExe() . ' --config=' . $oHostDbMaster->backrestConfig() . ' --stanza=' . $self->stanza() .
            ' ' . cfgCommandName(CFGCMD_ARCHIVE_GET);

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    archive.info missing');
        my $strSourceFile1 = $self->walSegment(1, 1, 1);
        storageTest()->pathCreate("${strWalPath}/archive_status");
        my $strArchiveFile1 = $self->walGenerate($strWalPath, PG_VERSION_94, 1, $strSourceFile1);

        $oHostDbMaster->executeSimple(
            $strCommandPush . " ${strWalPath}/${strSourceFile1}",
            {iExpectedExitStatus => ERROR_FILE_MISSING, oLogTest => $self->expect()});

        $oHostDbMaster->executeSimple(
            $strCommandGet . " ${strSourceFile1} ${strWalPath}/RECOVERYXLOG",
            {iExpectedExitStatus => ERROR_FILE_MISSING, oLogTest => $self->expect()});

        #---------------------------------------------------------------------------------------------------------------------------
        $oHostBackup->stanzaCreate(
            'stanza create',
            {strOptionalParam => '--no-' . cfgOptionName(CFGOPT_ONLINE)});

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    push first WAL');

        my @stryExpectedWAL;
        my $strSourceFile = $self->walSegment(1, 1, 1);
        my $strArchiveFile = $self->walGenerate($strWalPath, PG_VERSION_94, 2, $strSourceFile);

        $oHostDbMaster->executeSimple(
            $strCommandPush . ($bRemote ? ' --cmd-ssh=/usr/bin/ssh' : '') .
                " --compress-type=${strCompressType} ${strWalPath}/${strSourceFile}",
            {oLogTest => $self->expect()});
        push(@stryExpectedWAL, "${strSourceFile}-${strArchiveChecksum}.${strCompressType}");

        # Test that the WAL was pushed
        $self->archiveCheck($strSourceFile, $strArchiveChecksum, $strCompressType);

        # Remove from archive_status
        storageTest()->remove("${strWalPath}/archive_status/${strSourceFile}.ready");

        # Remove WAL
        storageTest()->remove("${strWalPath}/${strSourceFile}", {bIgnoreMissing => false});

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    get missing WAL');

        $oHostDbMaster->executeSimple(
            $strCommandGet . " 700000007000000070000000 ${strWalPath}/RECOVERYXLOG",
            {iExpectedExitStatus => 1, oLogTest => $self->expect()});

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    get first WAL');

        $oHostDbMaster->executeSimple(
            $strCommandGet . " ${strSourceFile} ${strWalPath}/RECOVERYXLOG", {oLogTest => $self->expect()});

        # Check that the destination file exists
        if (storageTest()->exists("${strWalPath}/RECOVERYXLOG"))
        {
            my ($strActualChecksum) = storageTest()->hashSize("${strWalPath}/RECOVERYXLOG");

            if ($strActualChecksum ne $strArchiveChecksum)
            {
                confess "recovered file hash '${strActualChecksum}' does not match expected '${strArchiveChecksum}'";
            }
        }
        else
        {
            confess "archive file '${strWalPath}/RECOVERYXLOG' is not in destination";
        }

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    push second WAL');

        # Generate second WAL segment
        $strSourceFile = $self->walSegment(1, 1, 2);
        $strArchiveFile = $self->walGenerate($strWalPath, PG_VERSION_94, 2, $strSourceFile);

        # Create a temp file to make sure it is deleted later (skip when S3 since it doesn't use temp files)
        my $strArchiveTmp;

        if (!$bS3)
        {
            # Should succeed when temp file already exists
            &log(INFO, '    succeed when tmp WAL file exists');

            $strArchiveTmp =
                $oHostBackup->repoPath() . '/archive/' . $self->stanza() . '/' . PG_VERSION_94 . '-1/' .
                    substr($strSourceFile, 0, 16) . "/${strSourceFile}-${strArchiveChecksum}.${strCompressType}" . qw{.} .
                    STORAGE_TEMP_EXT;

            storageTest()->put($strArchiveTmp, 'JUNK');
        }

        # Push the WAL
        $oHostDbMaster->executeSimple(
            "${strCommandPush} --compress-type=${strCompressType} --archive-async --process-max=2" .
                " ${strWalPath}/${strSourceFile}",
            {oLogTest => $self->expect()});
        push(@stryExpectedWAL, "${strSourceFile}-${strArchiveChecksum}.${strCompressType}");

        # Make sure the temp file no longer exists if it was created
        if (defined($strArchiveTmp))
        {
            my $oWait = waitInit(5);
            my $bFound = true;

            do
            {
                $bFound = storageTest()->exists($strArchiveTmp);
            }
            while ($bFound && waitMore($oWait));

            if ($bFound)
            {
                confess "${strArchiveTmp} should have been removed by archive command";
            }
        }

        # Test that the WAL was pushed
        $self->archiveCheck($strSourceFile, $strArchiveChecksum, $strCompressType, $oHostDbMaster->spoolPath());

        # Remove from archive_status
        storageTest()->remove("${strWalPath}/archive_status/${strSourceFile}.ready");

        # Remove from spool
        storageTest()->remove($oHostDbMaster->spoolPath() . '/archive/' . $self->stanza() . "/out/${strSourceFile}.ok");

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    push history file');

        storageTest()->put("${strWalPath}/00000002.history", 'HISTORYDATA');
        storageTest()->put("${strWalPath}/archive_status/00000002.history.ready", undef);

        $oHostDbMaster->executeSimple(
            "${strCommandPush} --archive-async ${strWalPath}/00000002.history",
            {oLogTest => $self->expect()});

        if (!storageRepo()->exists(STORAGE_REPO_ARCHIVE . qw{/} . PG_VERSION_94 . '-1/00000002.history'))
        {
            confess 'unable to find history file in archive';
        }

        storageTest()->remove("${strWalPath}/archive_status/00000002.history.ready");

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    db version mismatch error - archive-get unable to retrieve archiveId');

        # db section and corresponding history munged
        $oHostBackup->infoMunge(
            storageRepo()->pathGet(STORAGE_REPO_ARCHIVE . qw{/} . ARCHIVE_INFO_FILE),
            {&INFO_ARCHIVE_SECTION_DB_HISTORY => {'1' => {&INFO_ARCHIVE_KEY_DB_VERSION => '8.0'}}});

        $oHostDbMaster->executeSimple(
            $strCommandGet . " ${strSourceFile1} ${strWalPath}/RECOVERYXLOG",
            {iExpectedExitStatus => ERROR_ARCHIVE_MISMATCH, oLogTest => $self->expect()});

        # Restore the file to its original condition
        $oHostBackup->infoRestore(storageRepo()->pathGet(STORAGE_REPO_ARCHIVE . qw{/} . ARCHIVE_INFO_FILE));

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    db system-id mismatch error');

        $oHostBackup->infoMunge(
            storageRepo()->pathGet(STORAGE_REPO_ARCHIVE . qw{/} . ARCHIVE_INFO_FILE),
            {&INFO_ARCHIVE_SECTION_DB => {&INFO_BACKUP_KEY_SYSTEM_ID => 5000900090001855000},
            &INFO_ARCHIVE_SECTION_DB_HISTORY => {'1' => {&INFO_ARCHIVE_KEY_DB_ID => 5000900090001855000}}});

        $oHostDbMaster->executeSimple(
            $strCommandPush . " ${strWalPath}/${strSourceFile}",
            {iExpectedExitStatus => ERROR_ARCHIVE_MISMATCH, oLogTest => $self->expect()});

        $oHostDbMaster->executeSimple(
            $strCommandGet . " ${strSourceFile1} ${strWalPath}/RECOVERYXLOG",
            {iExpectedExitStatus => ERROR_ARCHIVE_MISMATCH, oLogTest => $self->expect()});

        # Restore the file to its original condition
        $oHostBackup->infoRestore(storageRepo()->pathGet(STORAGE_REPO_ARCHIVE . qw{/} . ARCHIVE_INFO_FILE));

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    stop');

        $oHostDbMaster->stop({strStanza => $oHostDbMaster->stanza()});

        $oHostDbMaster->executeSimple(
            $strCommandPush . " ${strWalPath}/${strSourceFile}",
            {iExpectedExitStatus => ERROR_STOP, oLogTest => $self->expect()});

        $oHostDbMaster->executeSimple(
            $strCommandGet . " ${strSourceFile1} ${strWalPath}/RECOVERYXLOG",
            {iExpectedExitStatus => ERROR_STOP, oLogTest => $self->expect()});

        $oHostDbMaster->start({strStanza => $oHostDbMaster->stanza()});

        storageTest->remove("${strWalPath}/RECOVERYXLOG", {bIgnoreMissing => false});

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    WAL duplicate ok');

        $oHostDbMaster->executeSimple($strCommandPush . " ${strWalPath}/${strSourceFile}", {oLogTest => $self->expect()});

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    WAL duplicate error');

        $strArchiveFile = $self->walGenerate($strWalPath, PG_VERSION_94, 1, $strSourceFile);

        $oHostDbMaster->executeSimple(
            $strCommandPush . " ${strWalPath}/${strSourceFile}",
            {iExpectedExitStatus => ERROR_ARCHIVE_DUPLICATE, oLogTest => $self->expect()});

        # Remove WAL
        storageTest()->remove("${strWalPath}/${strSourceFile}", {bIgnoreMissing => false});

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, "    get second WAL (${strSourceFile})");

        $oHostDbMaster->executeSimple(
            $strCommandGet . ($bRemote ? ' --cmd-ssh=/usr/bin/ssh' : '') . " --archive-async" . (!$bS3 ? " --repo-type=cifs" : '') .
                " --archive-timeout=5 ${strSourceFile} ${strWalPath}/RECOVERYXLOG",
            {oLogTest => $self->expect()});

        # Check that the destination file exists
        if (storageTest()->exists("${strWalPath}/RECOVERYXLOG"))
        {
            my ($strActualChecksum) = storageTest()->hashSize("${strWalPath}/RECOVERYXLOG");

            if ($strActualChecksum ne $strArchiveChecksum)
            {
                confess "recovered file hash '${strActualChecksum}' does not match expected '${strArchiveChecksum}'";
            }
        }
        else
        {
            confess "archive file '${strWalPath}/RECOVERYXLOG' is not in destination";
        }

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, "    get history file");

        $oHostDbMaster->executeSimple(
            $strCommandGet . " --archive-async 00000001.history ${strWalPath}/00000001.history",
            {iExpectedExitStatus => 1, oLogTest => $self->expect()});

        $oHostDbMaster->executeSimple(
            $strCommandGet . " --archive-async 00000002.history ${strWalPath}/00000002.history",
            {oLogTest => $self->expect()});

        if (${storageTest()->get("${strWalPath}/00000002.history")} ne 'HISTORYDATA')
        {
            confess 'history contents do not match original';
        }

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    .partial WAL');

        $strArchiveFile = $self->walGenerate($strWalPath, PG_VERSION_94, 2, "${strSourceFile}.partial");
        $oHostDbMaster->executeSimple(
            $strCommandPush . " ${strWalPath}/${strSourceFile}.partial",
            {oLogTest => $self->expect()});
        $self->archiveCheck("${strSourceFile}.partial", $strArchiveChecksum);

        push(@stryExpectedWAL, "${strSourceFile}.partial-${strArchiveChecksum}");

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    .partial WAL duplicate');

        $oHostDbMaster->executeSimple(
            $strCommandPush . " ${strWalPath}/${strSourceFile}.partial", {oLogTest => $self->expect()});
        $self->archiveCheck("${strSourceFile}.partial", $strArchiveChecksum);

        #---------------------------------------------------------------------------------------------------------------------------
        &log(INFO, '    .partial WAL with different checksum');

        $strArchiveFile = $self->walGenerate($strWalPath, PG_VERSION_94, 1, "${strSourceFile}.partial");
        $oHostDbMaster->executeSimple(
            $strCommandPush . " ${strWalPath}/${strSourceFile}.partial",
            {iExpectedExitStatus => ERROR_ARCHIVE_DUPLICATE, oLogTest => $self->expect()});

        #---------------------------------------------------------------------------------------------------------------------------
        $self->testResult(
            sub {storageRepo()->list(STORAGE_REPO_ARCHIVE . qw{/} . PG_VERSION_94 . '-1/0000000100000001')},
            '(' . join(', ', @stryExpectedWAL) . ')',
            'all WAL in archive', {iWaitSeconds => 5});
    }
}

1;
