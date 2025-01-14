#/**************************************************************************
# * Copyright(c) 2001-2002, ALICE Experiment at CERN, All rights reserved. *
# *                                                                        *
# * Author: The ALICE Off-line Project / AliEn Team                        *
# * Contributors are mentioned in the code where appropriate.              *
# *                                                                        *
# * Permission to use, copy, modify and distribute this software and its   *
# * documentation strictly for non-commercial purposes is hereby granted   *
# * without fee, provided that the above copyright notice appears in all   *
# * copies and that both the copyright notice and this permission notice   *
# * appear in the supporting documentation. The authors make no claims     *
# * about the suitability of this software for any purpose. It is          *
# * provided "as is" without express or implied warranty.                  *
# **************************************************************************/
package AliEn::Database::CE;

use AliEn::Database::TXT;
use Data::Dumper;
use strict;

use vars qw(@ISA);

@ISA = ("AliEn::Database::TXT");

sub initialize {
  my $self = shift;
  $self->{DIRECTORY} = "$self->{CONFIG}->{LOG_DIR}/CE.db";

  $self->{TABLES}->{JOBAGENT} = "agentId varchar(40), 
                               batchId varchar(60),
                               workernode varchar(300), 
                               timestamp int, 
                               jobId int,
                               status varchar(15), 
                               jdl varchar(1000)";

  $self->{TABLES}->{messages} = "jobId int,
                               procinfo varchar(200),
                               tag varchar(40),
                               timestamp int";

  $self->{TABLES}->{TOCLEANUP} = "batchId varchar(60),
                                timestamp int";

  return $self->SUPER::initialize();
}

sub insertJobAgent {
  my $self = shift;
  my $data = shift;
  $data->{timestamp} = time;
  $data->{status}    = "QUEUED";
  $self->debug(1, "insertJobAgent with " . Dumper($data) . " and @_");
  return $self->insert("JOBAGENT", $data, @_);
}

sub updateJobAgent {
  my $self = shift;
  my $data = shift;
  $data->{timestamp} = time;
  $data->{status}    = "ACTIVE";
  $self->info("Updating the jobagent");
  $self->debug(1, "updateJobAgent with " . Dumper($data) . " and @_");
  my $done = $self->update("JOBAGENT", $data, @_);
  if ($done =~ /^0E0$/) {

    #Ok, the increment did not work. Let's insert the entry
    $self->info("Inserting a new jobagent");
    $done = $self->insert("JOBAGENT", $data);
    $data->{jobId} and $self->info("Inserting info for job $data->{jobId}");
  }

  return $done;
}

sub getWaitingJobs {
  my $self = shift;
  my $ce = shift;
  $self->info("Getting waiting jobs for $ce");
  $self->debug(1, "getWaitingJobs with " . Dumper($ce) . " and @_");
  my $done = $self->queryValue("select count(1) from JOBAGENT where upper(workernode) like upper(?) and status like 'QUEUED'",undef,
    {bind_values=>[$ce]});

  return $done;
}

sub removeJobAgent {
  my $self         = shift;
  my $needsCleanUp = shift;
  my $data         = shift;
  my $key          = (keys(%$data))[0];    #Use the first key!
  $key or return;
  $data->{$key} or return;
  my $batchId = '';
  if ($needsCleanUp) {
    $self->debug(1, "This system needs JA cleanup");
    if ($data->{batchId}) {
      $self->debug(1, "Will cleanup JA with batchId=$data->{batchId}");
      $batchId = $data->{batchId};
    } else {
      $self->debug(1, "Will try to cleanup JA with $key=$data->{$key}");

      my $result = $self->query("SELECT batchId FROM JOBAGENT WHERE $key=?", undef, {bind_values => [ $data->{$key} ]});
      if ($result and @$result) {
        $result = (@$result)[0];    # take the first and hopefully only one
        $result->{batchId} and $batchId = $result->{batchId};
        $self->debug(1, "batchId is $batchId");
        if ($key eq 'jobId' and $batchId) {
          $self->info("Will not remove $batchId with $key=$data->{$key}");
          return 1;
        }
      }
    }
    if ($batchId) {
      $self->insert(
        "TOCLEANUP",
        { batchId   => $batchId,
          timestamp => time()
        }
      ) if $batchId;
    } else {
      $self->info("No idea how to remove JobAgent with $key=$data->{$key}");
    }
  }
  $self->debug(1, "Will remove JA with $key=$data->{$key}");
  $self->delete("JOBAGENT", "$key = ?", {bind_values => [ $data->{$key} ]});
  return 1;
}

sub insertJob {
  my $self    = shift;
  my $jobId   = shift;
  my $agentId = shift;
  my $time    = time;

  $self->info("Start insertJob $jobId $agentId");
  my $info = $self->query("SELECT * FROM JOBAGENT WHERE agentId=?", undef, {bind_values => [$agentId]});

  @$info
    or $self->info("In insertJob, did not find anything with agentId $agentId")
    and return;

  my $model = (@$info)[0];

  #    if( (@$info == 1) && !($model->{jobId})) {
  #	my $done = $self->updateJobAgent({jobId=>$jobId},"agentId=?",{bind_values=>[$agentId]});
  #	return $done;
  #    }

  $self->info(
"in insertJob, create entry in JOBAGENT with agentId: $agentId and jobId: $jobId (batchId: $model->{batchId}; workernode: $model->{workernode}; status: $model->{status}; jdl: $model->{jdl}"
  );

  my $done = $self->insertJobAgent(
    { agentId    => $agentId,
      batchId    => $model->{batchId},
      workernode => $model->{workernode},
      jobId      => $jobId,
      status     => $model->{status},
      jdl        => $model->{jdl}
    }
  );

  return $done;
}

sub insertMessage {
  my $self    = shift;
  my $jobId   = shift;
  my $tag     = shift;
  my $message = shift;
  my $update  = shift;
  defined $update or $update = 1;
  my $time = time;
  open(FILE, ">> $self->{CONFIG}->{LOG_DIR}/CE.db/messages.$$") or $self->info("Error opening the file") and return;
  $message =~ s/\n/\\n/g;
  print FILE "$jobId\t$tag\t$time\t$message\n";
  close FILE;

  return 1;

  #  $done or return;
  #  $update or return 1;
  #  $self->updateJobAgent({jobId=>$jobId},"jobId= ?", {bind_values=>[$jobId]});
}

sub retrieveMessages {
  my $self = shift;
  my $time = time;
  my $dir  = "$self->{CONFIG}->{LOG_DIR}/CE.db/todo/";
  (-d $dir) or mkdir $dir;
  system("mv $self->{CONFIG}->{LOG_DIR}/CE.db/messages.* $dir");
  $self->info("Reading the files from $dir");
  opendir(IMD, $dir) or $self->info("Cannot open directory $dir") and return;
  my $result = [];

  foreach my $file (readdir(IMD)) {
    $file =~ /^messages./ or next;
    open(FILE, "<$dir/$file") or $self->info("Error opening $file") and next;
    my $lines = 0;
    foreach my $l (<FILE>) {
      $lines++;
      my ($id, $tag, $time, $message) = split(/\t/, $l, 4);
      push @$result, {jobId => $id, tag => $tag, time => $time, procinfo => $message};
    }
    close FILE;
    unlink "$dir/$file";
    $self->info("Read $lines from $file");
  }
  closedir(IMD);
  return $result;
}

##############################################################################
##############################################################################

1;
