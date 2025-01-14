package AliEn::Service::Optimizer::Catalogue::Expired;
 
use strict;

use AliEn::Service::Optimizer::Catalogue;
use AliEn::Database::IS;


use vars qw(@ISA);
push (@ISA, "AliEn::Service::Optimizer::Catalogue");

sub checkWakesUp {
  my $self=shift;
  my $silent=shift;
  my @info;

  my $method="info";
  $silent and $method="debug" and  @info=1;

  $self->$method(@info, "The expired optimizer starts");
#  $self->updateQoS($silent) or return;

  my $db=$self->{DB} or return;
  my $tables=$db->query("select tableName, lfn from INDEXTABLE", undef, undef);
  foreach my $table (@$tables){
    $self->$method(@info,"Doing the table $table->{tableName} and $table->{lfn}");
    $self->checkExpired($silent, $db, "L$table->{tableName}L", $table->{lfn});
  }

  return;

}

#sub updateQoS{
#  my $self=shift;
#  my $silent=shift;

#  my $method="info";
#  my @debug=();
#  $silent and $method="debug" and @debug=1;
#  $self->$method(@debug, "Updating the QoS of the SE");
#  my ($hosts) = $self->{DB}->getAllHosts();
#  foreach my $tempHost (@$hosts) {  
#    print "Comparing $tempHost->{address}  eq $self->{CONFIG}->{IS_DB_HOST}\n";
#    if ($tempHost->{address}  eq $self->{CONFIG}->{IS_DB_HOST}){
#      $self->info("This is easy, same database");
#      $self->{DB}->do("update SE, $self->{CONFIG}->{IS_DATABASE}.SE set seQoS=protocols where seName=name ");
#    }else{
#      $self->info("This is tricky, different databaes");
#      my $IS=AliEn::Database::IS->new({ROLE=>'admin'}) or return;

#      my $seRef=$self->{DB}->queryColumn("select seName from SE");
#      foreach my $se (@$seRef){
#   $self->info("Looking for $se");
#   my $QoS=$IS->queryValue("SELECT protocols from SE where name='$se'");
#   $QoS or next;
#   $self->info("Setting the QoS of $se to $QoS");
#   $self->{DB}->update("SE", {seQoS=>$QoS}, "seName='$se'");
#      }
#    }
#  }
#  $self->$method(@debug, "QoS of the SE updated");
#  return 1
#}
sub checkExpired{
  my $self=shift;
  my $silent=shift;
  my $db=shift;
  my $table=shift;
  my $dir=shift;


  my $data=$db->query("SELECT * from $table where expiretime<now()")
    or $self->info("Error getting the triggers of $db->{DB}")
      and return;
  my $entryId=0;
  foreach my $entry (@$data){
    use Data::Dumper;
    $self->info("We have to do something with the entry".Dumper($entry));
    my $lfn="$dir/$entry->{lfn}";
    my $expiredLfn= $lfn.".expired";
    
    $self->{CATALOGUE}->execute("mv", $lfn, $expiredLfn);
    $self->{CATALOGUE}->execute("chown", "$entry->{owner}.$entry->{gowner}", $expiredLfn);
    $db->do("UPDATE $table set expiretime=NULL where lfn like ?", {bind_values=>[$entry->{lfn}.".expired"], zero_lengt=>0});
  
  }

  return 1;
}


return 1;
