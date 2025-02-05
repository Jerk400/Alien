package AliEn::LQ::Grid::EDT;

use AliEn::LQ::Grid;
use AliEn::Config;
@ISA = qw( AliEn::LQ::Grid );

use strict;


#sub initialize {
#  my $self=shift;
#  $self->{TXT}= new AliEn::Database::TXT::EDG;
#
#  $self->{TXT} or return;
#
#  $ENV{GLOBUS_LOCATION}="/opt/globus";#
#
#  delete $ENV{X509_CERT_DIR};#
#
#
#  return 1;
#
#}

sub getQueueStatus {
    my $self = shift;

    my $user = getpwuid($<);
    my @args=();
    $self->{CONFIG}->{CE_STATUSARG} and
      @args=split (/\s/, $self->{CONFIG}->{CE_STATUSARG});
 
    open( OUT, "dg-job-status -all -noint @args|" );
    my @output = <OUT>;
    close(OUT);
    return @output;
}

sub submit {
    my $self       = shift;
    my $executable = shift;
    my $arguments  = join " ", @_;


    my $file = "dg-submit.$$";
    my $tmpdir = "$self->{CONFIG}->{TMP_DIR}";
    if ( !( -d $self->{CONFIG}->{TMP_DIR} ) ) {
        my $dir = "";
        foreach ( split ( "/", $self->{CONFIG}->{TMP_DIR} ) ) {
            $dir .= "/$_";
            mkdir $dir, 0777;
        }
    }

    my $requirements=$self->GetJobRequirements();
    $requirements or return;

    open( BATCH, ">$tmpdir/$file.jdl" )
      or print STDERR "Can't open file '$tmpdir/$file.jdl': $!"
      and return;

    print BATCH "
\# JDL automatically generated by AliEn    
Executable = \"/bin/sh\";
Arguments = \"-v $file.sh $ENV{ALIEN_PROC_ID}\";
StdOutput = \"std.out\";
StdError = \"std.err\";
RetryCount = 7;
InputSandbox = {\"$tmpdir/$file.sh\"};
OutputSandbox = { \"std.err\" , \"std.out\" };
Environment = {\"ALIEN_PROC_ID=$ENV{ALIEN_PROC_ID}\", \\
               \"\", \\
               \"ALIEN_CM_AS_LDAP_PROXY=$ENV{ALIEN_CM_AS_LDAP_PROXY}\",\\
	       \"ALIEN_SE_MSS=$ENV{ALIEN_SE_MSS}\", \\
	       \"ALIEN_SE_FULLNAME=$ENV{ALIEN_SE_FULLNAME}\", \\
	       \"ALIEN_SE_SAVEDIR=$ENV{ALIEN_SE_SAVEDIR}\" \\
	       \"ALIEN_DISABLE_PACKAGES=1\" \\
               };
$requirements

";

    close BATCH;

    open( BATCH, ">$tmpdir/$file.sh" )
            or print STDERR "Can't open file '$tmpdir/$file.sh': $!"
            and return;
          print BATCH "#!/bin/sh
\# Script to run AliEn on EDG
eval `\$EDG_LOCATION/bin/edg-vo-env --shell=sh alice`
cd 
      
export ROOTSYS=\$ALICE_ROOT_DIR/root/3.05.02
export ALICE_GEANT=\$ALICE_ROOT_DIR/geant3/3.05.02
export PATH=\$PATH:\$ROOTSYS/bin
export LD_LIBRARY_PATH=\$ROOTSYS/lib:\$LD_LIBRARY_PATH
export ALICE=\$ALICE_ROOT_DIR/aliroot
export ALICE_LEVEL=3.09.06
export ALICE_ROOT=\$ALICE/\$ALICE_LEVEL
export ALICE_TARGET=`uname`
export ALIEN_JOB_TOKEN=\'$ENV{ALIEN_JOB_TOKEN}\'
export LD_LIBRARY_PATH=\$ALICE_GEANT/lib/tgt_\$ALICE_TARGET:\$ALICE_ROOT/lib/tgt_\$ALICE_TARGET:\$LD_LIBRARY_PATH
export PATH=\$PATH:\$ALICE_ROOT/bin/tgt_\$ALICE_TARGET:\$ALICE_ROOT/share

/home/alien/bin/alien --printenv
/home/alien/bin/alien RunJob \$1 --disablePack

cd ~ 
rm -f dg-submit.*.sh
";
    close BATCH;


    my @args=();
    $self->{CONFIG}->{CE_SUBMITARG} and 
     	@args=split (/\s/, $self->{CONFIG}->{CE_SUBMITARG});
    open( OUT, "dg-job-list-match  --noint @args $tmpdir/$file.jdl |grep jobmanager | " );
    my @output = <OUT>;
    close(OUT) or return 3;
    if (@output) {
      $self->{LOGGER}->info("CE","EDG matching resources found, submitting.");
      $self->debug(1,@output);
    } else { 
      $self->{LOGGER}->error("CE", "No EDG matching resource found, aborting.\n");
      return 2;
    }
    $self->debug(1,"DOING dg-job-submit --noint --nomsg  @args $tmpdir/$file.jdl\n");

    open SAVEOUT,  ">&STDOUT";
    if ( !open STDOUT, ">$self->{CONFIG}->{TMP_DIR}/stdout" ) {
        return 1;
    }
    my $error=system( "dg-job-submit", "--noint", "--nomsg", @args, "$tmpdir/$file.jdl" );

    close STDOUT;
    open STDOUT, ">&SAVEOUT";

    open (FILE, "<$self->{CONFIG}->{TMP_DIR}/stdout") or return 1;
    my $contact=<FILE>;
    close FILE; 
    $contact and 
      chomp $contact;

    if ($error) {
      $contact or $contact="";
      $self->{LOGGER}->warning("CE","Error submitting the job. Log file '$contact'\n");
      $contact and system ('cat', $contact);
      return $error;
    } else {
      $self->{LOGGER}->info("CE", "EDG JobID is $contact\n");
    }

    $self->{TXT}->do("INSERT INTO JOBS (queueid, contact) values  
                           ( $ENV{ALIEN_PROC_ID}, '$contact')");
    
    return $error;
}

sub GetJobRequirements {
    my $self=shift;

    my $requirements=( $self->{JDL_REQ} or "");

    $self->debug(1,"Generating GLUE-compliant JDL.");

    my $allreq= "Requirements = Member(other.GlueHostApplicationSoftwareRunTimeEnvironment, \"ALIEN-1.29.10\")";
    $allreq .= " &&  other.GlueHostNetworkAdapterOutboundIP==true ";
    $requirements =~ /other\.Packages/ 
	and $allreq .= " &&  Member(other.GlueHostApplicationSoftwareRunTimeEnvironment , \"ALICE-3.09.06\") ";
    $self->debug(1, "EDG requirements $allreq ;");
    $allreq .= " &&  other.GlueCEUniqueID==\"grid021.pd.infn.it:2119/jobmanager-lsf-glue\" ";

    $requirements=( $self->{JDL_SPECIAL_REQ} or "");

    $requirements and 
	$self->debug(1, "Adding $requirements") 
	    and $allreq .= "&& $requirements";

    return "$allreq ;";
}

return 1;




