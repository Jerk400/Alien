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
package AliEn::Database::Catalogue::LFN;

use AliEn::Database::Catalogue::Shared;
use strict;

=head1 NAME

AliEn::Database::Catalogue - database wrapper for AliEn catalogue

=head1 DESCRIPTION

This module interacts with a database of the AliEn Catalogue. The AliEn Catalogue can be distributed among several databases, each one with a different layout. In this basic layout, there can be several tables containing the entries of the catalogue. 

=cut

use vars qw(@ISA $DEBUG);

#This array is going to contain all the connections of a given catalogue
my %Connections;
push @ISA, qw(AliEn::Database::Catalogue::Shared);
$DEBUG=0;

=head1 SYNOPSIS

  use AliEn::Database::Catalogue;

  my $catalogue=AliEn::Database::Catalogue->new() or exit;


=head1 METHODS

=over

=cut


sub preConnect {
  my $self=shift;
  if (!$self->{UNIQUE_NM}){
    $self->{UNIQUE_NM}=time;
    #make sure that the number is unique
    while ($Connections{$self->{UNIQUE_NM}}){
      $self->{UNIQUE_NM}.="-1";
    }
    $Connections{$self->{UNIQUE_NM}}={FIRST_DB=>$self};
  }
  $self->{FIRST_DB}=$Connections{$self->{UNIQUE_NM}}->{FIRST_DB};
  $self->{DB} and $self->{HOST} and $self->{DRIVER} and return 1;
  $self->{CONFIG}->{CATALOGUE_DATABASE} or return;
  $self->info( "Using the default $self->{CONFIG}->{CATALOGUE_DATABASE}");
  ($self->{HOST}, $self->{DRIVER}, $self->{DB})
    =split ( m{/}, $self->{CONFIG}->{CATALOGUE_DATABASE});

  return 1;
}

sub initialize {
  my $self=shift;

  $self->{CURHOSTID}=$self->queryValue("SELECT hostIndex from HOSTS where address='$self->{HOST}' and driver='$self->{DRIVER}' and db='$self->{DB}'"); 
  $self->{CURHOSTID} or $self->info("Warning this host is not in the HOSTS table!!!") and return $self->SUPER::initialize(@_);

  my $dbindex="$self->{CONFIG}->{ORG_NAME}_$self->{CURHOSTID}";

  $Connections{$self->{UNIQUE_NM}}->{$dbindex}=$self;

  $self->{GUID}=AliEn::GUID->new() or 
    $self->info("Error creating the GUID interface") and  return;

  return $self->SUPER::initialize(@_);
}


=item C<createCatalogueTables>

This methods creates the database schema in an empty database. The tables that this implemetation have are:
HOSTS, 

=cut


#
# Checking the consistency of the database structure
sub createCatalogueTables {
  my $self = shift;


  $DEBUG and $self->debug(2,"In createCatalogueTables creating all tables...");

  foreach ("Constants", "SE") {
    my $method="check".$_."Table";
    $self->$method() or 
      $self->{LOGGER}->error("Catalogue", "Error checking the $_ table") and
	return;
  }

  my %tables=(HOSTS=>["hostIndex", {hostIndex=>"serial primary key",
				    address=>"char(50)", 
				    db=>"char(40)",
				    driver=>"char(10)", 
				    organisation=>"char(11)",},"hostIndex"],
	      TRIGGERS=>["lfn", {lfn=>"varchar(255)", 
				 triggerName=>"varchar(255)",
				entryId=>"int auto_increment primary key"}],
	      TRIGGERS_FAILED=>["lfn", {lfn=>"varchar(255)", 
				 triggerName=>"varchar(255)",
				entryId=>"int auto_increment primary key"}],
	      LFN_UPDATES=>["guid", {guid=>"binary(16)", 
				     action=>"char(10)",
				     entryId=>"int auto_increment primary key"},'entryId',['guid']
			   ],
	      ACL=>["entryId", 
		    {entryId=>"int(11) NOT NULL auto_increment primary key", 
		     owner=>"char(10) NOT NULL",
		     perm=>"char(4) NOT NULL",
		     aclId=>"int(11) NOT NULL",}, 'entryId'],
	      TAG0=>["entryId", 
		     {entryId=>"int(11) NOT NULL auto_increment primary key", 
		      path=>"varchar (255)",
		      tagName=>"varchar (50)",
		      tableName=>"varchar(50)"}, 'entryId'],
	      GROUPS=>["Userid", {Userid=>"int not null auto_increment primary key",
				  Username=>"char(15) NOT NULL", 
				  Groupname=>"char (85)",
				  PrimaryGroup=>"int(1)",}, 'Userid'],
	      INDEXTABLE=>["indexId", {indexId=>"int(11) NOT NULL auto_increment primary key",
				       lfn=>"varchar(50)", 
				       hostIndex=>"int(11)",
				       tableName=>"int(11)",}, 
			   'indexId', ['UNIQUE INDEX (lfn)']],
	      ENVIRONMENT=>['userName', {userName=>"char(20) NOT NULL PRIMARY KEY", 
					env=>"char(255)"}],
	      ACTIONS=>['action', {action=>"char(40) not null primary key",
				   todo=>"int(1) not null default 0"},
		       'action'],
	      PACKAGES=>['fullPackageName',{'fullPackageName'=> 'varchar(255)',
					    packageName=>'varchar(255)',
					    username=>'varchar(10)', 
					    packageVersion=>'varchar(255)',
					    platform=>'varchar(255)'}, 
			],
	     );
  foreach my $table (keys %tables){
    $self->info("Checking table $table");
    $self->checkTable($table, @{$tables{$table}}) or return;
  }

  $self->checkLFNTable("0") or return;
  $self->do("INSERT IGNORE INTO ACTIONS(action) values  ('PACKAGES')");
  $self->info("Let's create the functions");
  $self->do("create function string2binary (my_uuid varchar(36)) returns binary(16) deterministic sql security invoker return unhex(replace(my_uuid, '-', ''))");
  $self->do("create function binary2string (my_uuid binary(16)) returns varchar(36) deterministic sql security invoker return insert(insert(insert(insert(hex(my_uuid),9,0,'-'),14,0,'-'),19,0,'-'),24,0,'-')");
  $DEBUG and $self->debug(2,"In createCatalogueTables creation of tables finished.");


  1;
}

#
#
# internal functions
sub checkConstantsTable {
  my $self=shift;
  my %columns=(name=> "varchar(100) NOT NULL",
	       value=> "int",
	      );
  $self->checkTable("CONSTANTS",  "name", \%columns, 'name') or return;
  my $exists=$self->queryValue("SELECT count(*) from CONSTANTS where name='MaxDir'");
  $exists and return 1;
  return $self->do("INSERT INTO CONSTANTS values ('MaxDir', 0)");
}

sub checkLFNTable {
  my $self =shift;
  my $table =shift;
  defined $table or $self->info( "Error: we didn't get the table number to check") and return;
  
  $table =~ /^\d+$/ and $table="L${table}L";
  
  my %columns = (entryId=>"mediumint(11) NOT NULL auto_increment primary key", 
		 lfn=> "varchar(255) NOT NULL",
		 type=> "char(1) NOT NULL default 'f'",
		 ctime=>"timestamp",
		 expiretime=>"datetime",
		 size=>"int(11) not null default 0",
		 aclId=>"mediumint(11)",
		 perm=>"char(3) not null",
		 guid=>"binary(16)",
		 replicated=>"smallint(1) not null default 0",
		 dir=>"mediumint(11)",
		 owner=>"varchar(20) not null",
		 gowner=>"varchar(20) not null",
		);

  $self->checkTable(${table}, "entryId", \%columns, 'entryId', ['UNIQUE INDEX (lfn)',"INDEX(dir)", "INDEX(guid)"]) or return;
  
  $self->info("We should also check if the triggers exist");
  my $info=$self->query("show triggers like '$table\%'");
  use Data::Dumper;
  print Dumper($info);
  my $triggers={"${table}_insert"=>'NEW', "${table}_delete"=>'OLD',
		"${table}_update"=>"if ( NEW.guid != OLD.guid ) then insert into LFN_UPDATES(guid, action) VALUES (NEW.guid, 'insert'), (OLD.guid, 'delete');end if;"};
  foreach my $trigger (@$info) {
    print "Checking $trigger\n";
    $triggers->{$trigger->{Trigger}} or next;
    $self->info("The trigger $trigger->{Trigger} exists");
    delete $triggers->{$trigger->{Trigger}};
  }
  
  foreach my $triggerName (keys %$triggers){
    my $key=$triggerName;
    $key =~ s/^.*_//;
    $self->info("Creating the $key trigger");
    if ($key =~ /update/){
      $self->info("The update trigger is special");
      $self->do("create trigger $triggerName before $key on $table for each row $triggers->{$triggerName}") or return; 
    }else{
      $self->do("create trigger $triggerName before $key on $table for each row insert into LFN_UPDATES(guid,action) values ($triggers->{$triggerName}.guid, '$key')") or return ;
    }
  }
  return 1;
}

##############################################################################
##############################################################################
sub setIndexTable {
  my $self=shift;
  my $table=shift;
  my $lfn=shift;
  defined $table or return;
  $table =~ /^\d*$/ and $table="L${table}L";

  $DEBUG and $self->debug(2, "Setting the indextable to $table ($lfn)");
  $self->{INDEX_TABLENAME}={name=>$table, lfn=>$lfn};
  return 1;
}
sub getIndexTable {
  my $self=shift;
  return $self->{INDEX_TABLENAME};
}

sub getAllInfoFromLFN{
  my $self=shift;
  my $options=shift;

  my $tableName=$self->{INDEX_TABLENAME}->{name};
  $options->{table} and $options->{table}->{tableName} and 
    $tableName=$options->{table}->{tableName};
  my $tablePath=$self->{INDEX_TABLENAME}->{lfn};
  $options->{table} and $options->{table}->{lfn} and 
    $tablePath=$options->{table}->{lfn};
  defined $tableName or $self->info( "Error: missing the tableName in getAllInfoFromLFN") and return;
#  @_ or $self->info( "Warning! missing arguments in internal function getAllInfoFromLFN") and return;
  $tableName=~ /^\d+$/ and $tableName="L${tableName}L";
  my @entries=grep (s{^$tablePath}{}, @_);
  my @list=@entries;

  $DEBUG and $self->debug(2, "Checking for @entries in $tableName");
  my $op='=';
  ($options->{like}) and  $op="$options->{like}";

  map {$_="lfn $op ?"} @entries;

  my $where="WHERE ". join(" or ", @entries);
  my $opt=($options->{options} or "");
  ( $opt =~ /h/ ) and  $where .= " and lfn not like '%/.%'";
  ( $opt =~ /d/ ) and $where .= " and type='d'";
  ( $opt =~ /f/ ) and $where .= " and type='f'";

  my $order=$options->{order};
  $options->{where} and $where.=" $options->{where}";
  $order and $where .= " order by $order";

  if( $options->{retrieve}){
     $options->{retrieve} =~ s{lfn}{concat('$tablePath',lfn) as lfn};
     $options->{retrieve} =~ s{guid}{binary2string(guid) as guid};
   }
  my $retrieve=($options->{retrieve} or "*,concat('$tablePath',lfn) as lfn, binary2string(guid) as guid,DATE_FORMAT(ctime, '%b %d %H:%i') as ctime");

  my $method=($options->{method} or "query");

  if ($options->{exists}) {
    $method="queryValue";
    $retrieve="count(*)";
  }

  $options->{bind_values} and push @list, @{$options->{bind_values}};

  my $DBoptions={bind_values=>\@list};

  return $self->$method("SELECT $retrieve FROM $tableName $where", undef, $DBoptions);
}

=item c<existsLFN($lfn)>

This function receives an lfn, and checks if it exists in the catalogue. It checks for lfns like '$lfn' and '$lfn/', and, in case the entry exists, it returns the name (the name has a '/' at the end if the entry is a directory)

=cut

sub existsLFN {
  my $self=shift;
  my $entry=shift;

  $entry=~ s{/?$}{};
  my $options={bind_values=>["$entry/"]};
  my $tableRef=$self->queryRow("SELECT tableName,lfn from INDEXTABLE where ? like concat(lfn,'%') order by length(lfn) desc limit 1",undef, $options);
  defined $tableRef or return;
  return $self->getAllInfoFromLFN({method=>"queryValue",
				      retrieve=>"lfn", table=>$tableRef}
				     , $entry, "$entry/");

}

=item C<getHostsForEntry($lfn)>

This function returns a list of all the possible hosts and tables that might contain entries of a directory

=cut

sub getHostsForEntry{
  my $self=shift;
  my $lfn=shift;

  $lfn =~ s{/?$}{};
  #First, let's take the entry that has the directory
  my $entry=$self->query("SELECT tableName,hostIndex,lfn from INDEXTABLE where '$lfn/' like concat(lfn,'%') order by length(lfn) desc limit 1");
  $entry or return;
  #Now, let's get all the possibles expansions (but the expansions at least as
  #long as the first index
  my $length=length (${$entry}[0]->{lfn});
  my $expansions=$self->query("SELECT distinct tableName, hostIndex,lfn from INDEXTABLE where lfn like '$lfn/%' and length(lfn)>$length");
  my @all=(@$entry, @$expansions);
  return \@all;
}


=item C<createFile($hash)>

Adds a new file to the database. It receives a hash with the following information:



=cut

sub createFile {
  my $self=shift;
  my $options=shift || "";
  my $tableName= $self->{INDEX_TABLENAME}->{name};
  my $tableLFN= $self->{INDEX_TABLENAME}->{lfn};
  my $entryDir;
  my $seNumbers={};
  my @inserts=@_;
  foreach my $insert (@inserts) {
    $insert->{type}='f';
    $entryDir or $entryDir=$self->getParentDir($insert->{lfn});
    $insert->{dir}=$entryDir;
    $insert->{lfn}=~ s{^$tableLFN}{};
    foreach my $key (keys %$insert){
      $key=~ /^guid$/ and next;
      if ($key=~ /^(se)|(md5)|(pfn)|(pfns)$/){
	delete $insert->{$key};
	next;
      }
      $insert->{$key}="'$insert->{$key}'";
    }
    if ( $insert->{guid}) {
      $insert->{guid}="string2binary('$insert->{guid}')";
    }
  }
  $self->info("Inserting the lfn");
  my $done= $self->multiinsert($tableName, \@inserts, {noquotes=>1,silent=>1});
  if (!$done and $DBI::errstr=~ /Duplicate entry '(\S+)'/ ){
    $self->info("The entry '$tableLFN$1' already exists");
  }

  return $done;
}

#
# This subroutine returns the guid of an LFN. Before calling it, 
# you have to make sure that you are in the right database 
# (with checkPersmissions for instance)
sub getGUIDFromLFN{
  my $self=shift;

  return $self->getAllInfoFromLFN({retrieve=>'guid', method=>'queryValue'}, @_);
}

sub getParentDir {
  my $self=shift;
  my $lfn=shift;
  $lfn=~ s{/[^/]*/?$}{/};

  my $tableName= $self->{INDEX_TABLENAME}->{name} or return;
  $lfn=~ s{$self->{INDEX_TABLENAME}->{lfn}}{};
  return $self->queryValue("select entryId from $tableName where lfn=?", undef, 
			   {bind_values=>[$lfn]});
}
sub updateLFN {
  my $self=shift;
  $self->info("*********************Inn updateFile with @_");
  my $file=shift;
  my $update=shift;

  my $lfnUpdate={};

  my $options={noquotes=>1};
  
  $update->{size} and $lfnUpdate->{size}= $update->{size};
  $update->{guid} and $lfnUpdate->{guid}="string2binary(\"$update->{guid}\")";
  $update->{owner} and $lfnUpdate->{owner}= "\"$update->{owner}\"";
  $update->{gowner} and $lfnUpdate->{gowner}= "\"$update->{gowner}\"";

  #maybe all the information to update was only on the guid side
  (keys %$lfnUpdate) or return 1;
  my $tableName=$self->{INDEX_TABLENAME}->{name};
  my $lfn=$self->{INDEX_TABLENAME}->{lfn};

  $self->info("There is something to update!!");
  $file=~ s{^$lfn}{};
  $self->update($tableName, $lfnUpdate, "lfn='$file'", {noquotes=>1}) or 
    return;
  $file and return 1;

  $self->info("This is in fact an index!!!!");
  my $parentpath=$lfn;
  #If it is /, we don't have to do anything
  ($parentpath =~ s{[^/]*/?$}{}) or return 1;

  $self->info("HERE WE SHOULD UPDATE ALSO THE FATHER");

  my $db=$self->selectDatabase($parentpath);
  $lfn=~ s{^$db->{INDEX_TABLENAME}->{lfn}}{};
  return $db->update($db->{INDEX_TABLENAME}->{name}, $lfnUpdate, "lfn='$lfn'", {noquotes=>1});
}

sub deleteFile {
  my $self=shift;
  my $file=shift;

  my $tableName=$self->{INDEX_TABLENAME}->{name};
#  my $index=",$self->{CURHOSTID}_$tableName,";
  $file=~ s{^$self->{INDEX_TABLENAME}->{lfn}}{};

#  my $guid=$self->queryValue("select guid from $tableName where lfn='$file'");
#  if ($guid) {
#    $self->debug(1, "Removing the value $index from the GUID $guid");
#    my $done= $self->{FIRST_DB}->do("update GUID set lfn=if(locate('$index', lfn), concat(left(lfn,locate('$index',lfn)), substring(lfn, length('$index')+locate('$index',lfn))), lfn) where guid='$guid'");
#  }

  return $self->delete($tableName, "lfn='$file'");
}
sub getLFNlike {
  my $self=shift;
  my $lfn=shift;

  my @result;

  $self->debug(1, "Trying to find paths like $lfn");
  #Take as the starting point the lfn up to the first % or _
  my $starting=$lfn;
  $lfn =~ s/([^\\])\*/$1%/g;
  $lfn =~ s/([^\\])\?/$1_/g;
  $starting=~ s/[\%\_\*\?].*$//;

  my $pos=length $starting;
  $pos--;
  $pos<0 and $pos=0;


  #First, look in the index for possible tables;
  my $indexRef=$self->query("SELECT HOSTS.hostIndex, tableName,lfn,length(lfn) as length FROM INDEXTABLE, HOSTS where '$starting' like concat(lfn, '%') and INDEXTABLE.hostIndex=HOSTS.hostIndex order by length(lfn) desc limit 1");

  $indexRef or $self->info( "Error trying to find the indexes for $starting") and return;

  my $indexRef2=$self->query("SELECT HOSTS.hostIndex, tableName,lfn FROM INDEXTABLE, HOSTS where lfn like '$starting\%' and INDEXTABLE.hostIndex=HOSTS.hostIndex and length(lfn)>${$indexRef}[0]->{length}");



  my @dirs=split(/\//, $lfn);
  my $pattern="";
  foreach my $dir (@dirs) {
    $dir=~ s{^%}{\[^/\]+};
    $dir=~ s{([^\\])%}{$1\[^/\]*}g;
    $pattern.="$dir/";
  }
  $pattern .= "?\$";



  #now, for each index, find the matching lfn
  foreach my $ref (@$indexRef, @$indexRef2){
    my $db=$self->reconnectToIndex( $ref->{hostIndex}) or next;
    my $orig="concat('$ref->{lfn}', lfn)";
    my $ppattern=$pattern;
    #If the entries that we are looking for already have the 
    #start lfn of this table, we don't have to put it in the
    #search
    if ($ppattern =~ s{^$ref->{lfn}}{}) {
      $orig="lfn";
    }
    my $query="SELECT concat('$ref->{lfn}',lfn) from L$ref->{tableName}L where $orig rlike '^$ppattern'";
    $self->debug(1, "Doing $query");
    my $temp=$db->queryColumn($query);
    push @result, @$temp;

  }

  return \@result;
}
##############################################################################
##############################################################################
#
# Lists a directory: WARNING: it doesn't return '..'
#

=item C<listDirectory($entry, $options)>

Returns all the entries of a directory. '$entry' can be either an lfn (in which case listDirectory will retrieve the rest of the info from the database), or a hash containing the info of that directory. 

Possible options:

=over

=item a

list also the current directory

=item f

Do not sort the output

=item F

put a '/' at the end of directories


=back


=cut

sub listDirectory {
  my $self=shift;
  my $info=shift;
  my $options=shift || "";
  
  my $entry;

  if ( UNIVERSAL::isa( $info, "HASH" )) {
    $entry=$info;
  } else {
    $entry=$self->getAllInfoFromLFN({method=>"queryRow"}, $info); 
    $entry or $self->info( "Error getting the info of $info") and return;
  }
  my $sort="order by lfn";
  $options =~ /f/ and $sort="";
  my $content=$self->getAllInfoFromLFN({table=>$self->{INDEX_TABLENAME}, 
					   where=>"dir=? $sort",
					   bind_values=>[$entry->{entryId}]});
  my @all;
  $content and push @all, @$content;
  if ($options=~ /a/) {
    $entry->{lfn}=".";
    @all=($entry,@all);
  }
  if ($options !~ /F/) {
    foreach my $entry2 (@all) {
      $entry2->{lfn}=~ s{/$}{};
    }
  }
  return @all;
}

#
# createDirectory ($lfn, [$perm, [$replicated, [$table]]])
#
sub createDirectory {
  my $self=shift;
  my $insert={lfn=>shift,
	      perm=>(shift or "755"),
	      replicated=>(shift or 0),
	      owner=>$self->{ROLE},
	      gowner=>$self->{ROLE},
	      type=>'d'};
  my $tableRef=shift || {};

  my $tableName=$tableRef->{name} || $self->{INDEX_TABLENAME}->{name};
  my $tableLFN=$tableRef->{lfn} || $self->{INDEX_TABLENAME}->{lfn};
#  delete $insert->{table};

  $tableName =~ /^\d*$/ and $tableName="L${tableName}L";

  $insert->{dir}=$self->getParentDir($insert->{lfn});
  $insert->{lfn} =~ s{^$tableLFN}{};

  return $self->insert($tableName, $insert);
}
sub createRemoteDirectory {
  my $self=shift;
  my ($hostIndex,$host, $DB, $driver,  $lfn)=@_;
  my $oldtable=$self->{INDEX_TABLENAME};

  my ( $oldHost, $oldDB, $oldDriver ) = 
    ( $self->{HOST},$self->{DB}, $self->{DRIVER});

  #Now, in the new database
  $self->info("Before reconnecttoindex\n");
  my $db=$self->reconnectToIndex($hostIndex) or $self->info("Error: the reconnect to index $hostIndex failed") and return;
  my $newTable=$db->getNewDirIndex() or $self->info("Error getting the new dirindex") and return;
  $newTable="L${newTable}L";
  #ok, let's insert the entry in $table
  $self->info("Before callting createDirectory");
  my $done=$db->createDirectory("$lfn/",$self->{UMASK},0,{name=>$newTable, lfn=>"$lfn/"} );

  $done or $self->info("Error creating the directory $lfn") and return;
  $self->info("Directory $lfn/ created");
  $self->info( "Now, let's try to do insert the entry in the INDEXTABLE");
  if (! $self->insertInIndex($hostIndex, $newTable, "$lfn/")){
    $db->delete($newTable, "lfn='$lfn/'");
    return;
  }
  $self->info( "Almost everything worked!!");
  $self->createDirectory("$lfn/",$self->{UMASK}, 1 ,$oldtable) or return;
  $self->info( "Everything worked!!");

  return $done;

}

sub removeDirectory {
  my $self=shift;
  my $path=shift;
  my $parentdir=shift;
  
  #Let's get all the hosts that can have files under this directory
  my $entries=$self->getHostsForEntry($path) or 
    $self->info( "Error getting the hosts for '$path'") and return;
  $DEBUG and $self->debug(1, "Getting dir from $path");
  my @index=();

  foreach my $db (@$entries) {
    $DEBUG and $self->debug(1, "Deleting all the entries from $db->{hostIndex} (table $db->{tableName} and lfn=$db->{lfn})");
    my $db2=$self->reconnectToIndex($db->{hostIndex}, $path);
    $db2 or  $self->info( "Error reconecting") and next;

    my $tmpPath="$path/";
    $tmpPath=~ s{^$db->{lfn}}{};
    $db2->delete("L$db->{tableName}L", "lfn like '$tmpPath%'");
    $db->{lfn} =~ /^$path/ and push @index, "$db->{lfn}\%";
  }

  if ($#index>-1) {
    $DEBUG and $self->debug(1, "And now, let's clean the index table (@index)");
    $self->deleteFromIndex(@index);
    if (grep( m{^$path/?\%$}, @index)){
      $DEBUG and $self->debug(1, "The directory we were trying to remove was an index");
      my $entries=$self->getHostsForEntry($parentdir) or 
	$self->info( "Error getting the hosts for '$path'") and return;
      my $db=${$entries}[0];
      my $newdb=$self->reconnectToIndex($db->{hostIndex}, $parentdir);
      $newdb or $self->info( "Error reconecting") and return;
      my $tmpPath="$path/";
      $tmpPath=~ s{^$db->{lfn}}{};
      $newdb->delete("L$db->{tableName}L", "lfn='$tmpPath'");
    }
  }
  return 1;
}

sub getSENumber{
  my $self=shift;
  my $se=shift;
  my $options=shift || {};
  $DEBUG and $self->debug(2, "Checking the senumber");
  defined $se or return 0;
  $DEBUG and $self->debug(2, "Getting the numbe from the list");
  my $senumber=$self->queryValue("SELECT seNumber FROM SE where seName=?", undef, 
				 {bind_values=>[$se]});
  defined $senumber and return $senumber;
  $DEBUG and $self->debug(2, "The entry did not exist");
  $options->{existing} and return;
  $self->{SOAP} or $self->{SOAP}=new AliEn::SOAP 
    or return ;

  my $result=$self->{SOAP}->CallSOAP("Authen", "addSE", $se) or return;
  my $seNumber=$result->result;
  $DEBUG and $self->debug(1,"Got a new number $seNumber");
  return $seNumber;
  
  my $newnumber=1;


  my $max=$self->queryValue("SELECT max(seNumber) FROM SE");
  if ($max) {
    $newnumber=$max*2;
  }
  $self->insert("SE", {seName=>$se, seNumber=>$newnumber}) or return;
  return $newnumber;
}
sub tabCompletion {
  my $self=shift;
  my $entryName=shift;
  my $tableName=$self->{INDEX_TABLENAME}->{name};
  my $lfn=$self->{INDEX_TABLENAME}->{lfn};
  my $dirName=$entryName;
  $dirName=~ s{[^/]*$}{};
  $dirName =~ s{^$lfn}{};
  $entryName =~ s{^$lfn}{};
  my $dir=$self->queryValue("SELECT entryId from $tableName where lfn=?",undef,
			    {bind_values=>[$dirName]});
  $dir or return;
  my $rfiles = $self->queryColumn("SELECT concat('$lfn',lfn) from $tableName where dir=$dir and lfn rlike '^$entryName\[^/]*\/?\$'");
  return @$rfiles;

}
##############################################################################
##############################################################################
sub actionInIndex {
  my $self=shift;
  my $action=shift;

  #updating the D0 of all the databases
  my ($hosts) = $self->getAllHosts;

  defined $hosts
    or return;
  my ( $oldHost, $oldDB, $oldDriver ) = ($self->{HOST}, $self->{DB}, $self->{DRIVER});
  my $tempHost;
  foreach $tempHost (@$hosts) {
    #my ( $ind, $ho, $d, $driv ) = split "###", $tempHost;
    $self->info( "Updating the INDEX table of  $tempHost->{db}");
    my $db=$self->reconnectToIndex( $tempHost->{hostIndex}, "", $tempHost );
    $db or next;
    $db->do($action) or print STDERR "Warning: Error doing $action";
  }
  $self->reconnect( $oldHost, $oldDB, $oldDriver ) or return;

  $DEBUG and $self->debug(2, "Everything is done!!");

  return 1;
}
sub insertInIndex {
  my $self=shift;
  my $hostIndex=shift;
  my $table=shift;
  my $lfn=shift;
  
  $table=~ s/^L(\d+)L$/$1/;
  my $action="INSERT INTO INDEXTABLE (hostIndex, tableName, lfn) values('$hostIndex', '$table', '$lfn')";
  return $self->actionInIndex($action);
}
sub deleteFromIndex {
  my $self=shift;
  my @entries=@_;
  map {$_="lfn like '$_'"} @entries;
  my $action="DELETE FROM INDEXTABLE WHERE ".join(" or ", @entries);
  return $self->actionInIndex($action);
  
}
sub getAllIndexes {
  my $self=shift;
  return $self->query("SELECT * FROM INDEXTABLE");
  
}

=item C<copyDirectory($source, $target)>

This subroutine copies a whole directory. It checks if part of the directory is in a different database

=cut

sub copyDirectory{
  my $self=shift;
  my $options=shift;
  my $source=shift;
  my $target=shift;
  $source and $target or
    $self->info( "Not enough arguments in copyDirectory",1111) and return;
  $source =~ s{/?$}{/};
  $target =~ s{/?$}{/};
  $DEBUG and $self->debug(1,"Copying a directory ($source to $target)");

  # Let's check where the source is:
  my $sourceHosts=$self->getHostsForEntry($source);

  my $sourceInfo=$self->getIndexHost($source);

  my $targetHost=$self->getIndexHost($target);
  my $targetIndex=$targetHost->{hostIndex};
  my $targetTable="L$targetHost->{tableName}L";
  my $targetLFN=$targetHost->{lfn};


  my $user=$options->{user} || $self->{ROLE};

  #Before doing this, we have to make sure that we are in the right database
  my $targetDB=$self->reconnectToIndex( $targetIndex) or return;

  my $sourceLength=length($source)+1;

  my $targetName=$targetDB->existsLFN($target);
  if ($targetName)  {
    if ($targetName!~ m{/$} ) {
      $self->info("cp: cannot overwrite non-directory `$target' with directory `$source'", "222");
      return;
    }
    my $sourceParent=$source;
    $sourceParent=~ s {/([^/]+/?)$}{/};
    $self->info( "Copying into an existing directory (parent is $sourceParent)");
    $sourceLength=length($sourceParent)+1;
    $options->{k}  and $sourceLength=length($source)+1;
  }
  my $beginning=$target;
  $beginning=~ s/^$targetLFN//;
  
  my $select="insert into $targetTable(lfn,owner,gowner,size,type,guid,perm,dir) select concat('$beginning',substring(concat('";
  my $select2="', lfn), $sourceLength)) as lfn, '$user', '$user',size,type,guid,perm,-1 ";
  my @values=();

  foreach my $entry (@$sourceHosts){
    $DEBUG and $self->debug(1, "Copying from $entry to $targetIndex and $targetTable");
    my $db=$self->reconnectToIndex( $entry->{hostIndex});

    my $tsource=$source;
    $tsource=~ s{^$entry->{lfn}}{};
    my $like="replicated=0 and lfn like '$tsource%'";
    $options->{k} and $like.=" and lfn!='$tsource'";
    if ($targetIndex eq $entry->{hostIndex}){
      my $table="L$entry->{tableName}L";
      $DEBUG and $self->debug(1, "This is easy: from the same database");
      # we want to copy the lf, which in fact would be something like
      # substring(concat('$entry->{lfn}', lfn), length('$sourceIndex'))
      $self->do("$select$entry->{lfn}$select2 from $table where $like");
#      $self->{FIRST_DB}->do("update GUID, $table set GUID.lfn=concat(GUID.lfn, '${targetIndex}_$targetTable,') where GUID.guid=$table.guid and $table.lfn  like '$tsource%' and $table.replicated=0");

    }else {
      $DEBUG and $self->debug(1, "This is complicated: from another database");
      my $entries = $db->query("SELECT concat('$beginning', substring(concat('$entry->{lfn}',lfn), $sourceLength )) as lfn, size,type,binary2string(guid) as guid ,perm FROM L$entry->{tableName}L where $like");
      foreach  my $files (@$entries) {
	my $guid="NULL";
	(defined $files->{guid}) and  $guid="$files->{guid}";

	$files->{lfn}=~ s{^}{};
	$files->{lfn}=~ s{^$targetLFN}{};
	push @values, " ( '$files->{lfn}',  '$user', '$user', '$files->{size}', '$files->{type}', string2binary('$guid'), '$files->{perm}', -1)";

      }
    }

  }
  if ($#values>-1) {
    my $insert="INSERT into $targetTable(lfn,owner,gowner,size,type,guid,perm,dir) values ";

    $insert .= join (",", @values);
    $targetDB->do($insert);
  }

  $target=~ s{^$targetLFN}{};
  my $targetParent=$target;
  $targetParent=~ s{/[^/]+/?$}{/} or $targetParent="";;  
  $DEBUG and $self->debug(1, "We have inserted the entries. Now we have to update the column dir");

  #and now, we should update the entryId of all the new entries

  my $entries=$targetDB->query("SELECT lfn, entryId from $targetTable where (dir=-1 and lfn like '$target\%/') or lfn='$target' or lfn='$targetParent'");
  foreach my $entry (@$entries) {
    $DEBUG and $self->debug(1, "Updating tbe entry $entry->{lfn}");
    my $update="update $targetTable set dir=$entry->{entryId} where dir=-1 and lfn rlike '^$entry->{lfn}\[^/]+/?\$'";
    $targetDB->do($update);
    
  }
#  $db2=$self->reconnectToIndex($sourceInfo->{hostIndex});
#  $self=$db;

  $DEBUG and $self->debug(1,"Directory copied!!");
  return 1;
}

#sub reconnectToIndex{
#  my $self=shift;
#  my $hostIndex=shift;
#  my $info=$self->queryRow("SELECT address, db,driver from HOSTS where hostIndex=$hostIndex") or $self->info( "Error getting the info of the host $hostIndex") and return;
#  my ($db, $host, $driver)=($info->{db}, $info->{address}, $info->{driver});#
#
#  ($db eq $self->{DB}) and ($host eq $self->{HOST}) and 
#    ($driver  eq $self->{DRIVER}) and return 1;
#  $DEBUG and $self->debug(1, "Reconecting to the database $db,$host, $driver");
#  return $self->reconnect($host, $db, $driver);
#
#}

=item C<moveLFNs($lfn, $toTable)>

This function moves all the entries under a directory to a new table
A new table is always created.

Before calling this function, you have to be already in the right database!!!
You can make sure that you are in the right database with a call to checkPermission

=cut

sub moveLFNs {
  my $self=shift;
  my $lfn=shift;

  $DEBUG and $self->debug(1,"Starting  moveLFNs, with $lfn ");
  my   $toTable=$self->getNewDirIndex();
  defined $toTable or $self->info( "Error getting the name of the new table") and return;


  my $isIndex=$self->queryValue("SELECT 1 from INDEXTABLE where lfn=?", undef,
			       {bind_values=>[$lfn]});


  my $entry=$self->getIndexHost($lfn) or $self->info( "Error getting the info of $lfn") and return;
  my $sourceHostIndex=$entry->{hostIndex};
  my $fromTable=$entry->{tableName};
  my $fromLFN=$entry->{lfn};

  $toTable =~ /^(\d+)*$/ and $toTable= "L${toTable}L";
  $fromTable =~ /^(\d+)*$/ and $fromTable= "L${fromTable}L";

  defined $sourceHostIndex or $self->info( "Error getting the hostindex of the table $toTable") and return;

  if ($isIndex ) {
    $DEBUG and $self->debug(1, "This is in fact an index...");
    my $parent=$lfn;
    $parent =~ s{/[^/]*/$}{/};
    my $entryP=$self->getIndexHost($parent) or $self->info( "Error getting the info of $parent") and return;
    my $parentTable=$entryP->{tableName};
  }

  #ok, this is the easy case, we just copy into the new table
  my $columns="entryId,owner,gowner,replicated,aclId,expiretime,size,dir,type,guid,perm";
  my $tempLfn=$lfn;
  $tempLfn=~ s{$fromLFN}{};
  #First, let's insert the entries in the new table
  $self->do("INSERT into $toTable($columns,lfn) select $columns,substring(concat('$fromLFN', lfn), length('$lfn')+1) from $fromTable where lfn like '${tempLfn}%'") or return;

  ($isIndex) and  $self->deleteFromIndex($lfn);

  if (!$self->insertInIndex($sourceHostIndex, $toTable, $lfn)){
    $self->delete($toTable,"lfn like '${tempLfn}%'");
    return;
  }
  if (!$isIndex ){
    #Finally, let's delete the old table;
    $self->delete($fromTable,"lfn like '${tempLfn}_%'");
    $self->update($fromTable,{replicated=>1}, "lfn='$tempLfn'");
  } else {
    $self->delete($fromTable,"lfn like '${tempLfn}%'");
  }

  return 1;
}
##############################################################################
##############################################################################

sub grantBasicPrivilegesToUser {
  my $self = shift;
  my $db = shift
    or $self->{LOGGER}->error("Catalogue","In grantBasicPrivilegesToUser database name is missing")
      and return;
  my $user = shift
    or $self->{LOGGER}->error("Catalogue","In grantBasicPrivilegesToUser user is missing")
      and return;
  my $passwd = shift;

  $self->grantPrivilegesToUser(["EXECUTE ON *"], $user, $passwd)
    or return;

  my $rprivileges = ["SELECT ON $db.*",
		     "INSERT, DELETE ON $db.TAG0"];


  $DEBUG and $self->debug(2,"In grantBasicPrivilegesToUser granting privileges to user $user"); 
  $self->grantPrivilegesToUser($rprivileges, $user);
}

sub grantExtendedPrivilegesToUser {
  my $self = shift;
  my $db = shift
    or $self->{LOGGER}->error("Catalogue","In grantExtendedPrivilegesToUser database name is missing")
	and return;
  my $user = shift
    or $self->{LOGGER}->error("Catalogue","In grantExtendedPrivilegesToUser user is missing")
	and return;
  my $passwd = shift;

  $self->grantPrivilegesToUser(["SELECT ON $db.*"], $user, $passwd)
  	or return;

  my $rprivileges = [
		     "INSERT, DELETE  ON $db.TAG0",
#		     "INSERT, DELETE ON $db.FILES",
		     "INSERT, DELETE ON $db.ENVIRONMENT", 
#		     "INSERT ON $db.SE"
		     "EXECUTE ON *",
		     "UPDATE ON $db.ACTIONS",
];

  $DEBUG and $self->debug(2,"In grantExtendedPrivilegesToUser granting privileges to user $user"); 
  $self->grantPrivilegesToUser($rprivileges, $user);
}


sub getNewDirIndex {
  my $self=shift;

  $self->lock("CONSTANTS");

  my ($dir) = $self->queryValue("SELECT value from CONSTANTS where name='MaxDir'");
  $dir++;
  
  $self->update("CONSTANTS", {value => $dir}, "name='MaxDir'");
  $self->unlock();

  $self->info( "New table number: $dir");

  $self->checkLFNTable($dir) or 
    $self->info( "Error checking the tables $dir") and return;

  return $dir;
}


#
#Returns the name of the file of a path
#
sub _basename {
  my $self = shift;
  my ($arg) = @_;
  my $pos = rindex( $arg, "/" );

  ( $pos < 0 ) and    return ($arg);

  return ( substr( $arg, $pos + 1 ) );
}

sub deleteLink {
    my $self = shift;
    my $parent = shift;
    my $basename = shift;
    my $newpath = shift;

    $self->deleteDirEntry($parent, $basename);
    $self->deleteFromD0Like($newpath);
}

### Hosts functions

sub getFieldFromHosts{
  my $self = shift;
  my $host = shift
    or $self->{LOGGER}->error("Catalogue","In getFieldFromHosts host index is missing")
      and return;
  my $attr = shift || "*";
  
  $DEBUG and $self->debug(2,"In getFieldFromHosts fetching value of attribute $attr for host index $host");
  $self->queryValue("SELECT $attr FROM HOSTS WHERE hostIndex = ?", undef, 
		    {bind_values=>[$host]});
}

sub getFieldsFromHostsEx {
    my $self = shift;
	my $attr = shift || "*";
    my $where = shift || "";

	$self->query("SELECT $attr FROM HOSTS $where");
}

sub getFieldFromHostsEx {
    my $self = shift;
	my $attr = shift || "*";
    my $where = shift || "";

	$self->queryColumn("SELECT $attr FROM HOSTS $where");
}

sub getHostIndex {
    my $self = shift;
    my $host = shift;
    my $DB = shift;
    my $driver = shift;

    $driver
      and $driver = " AND driver='$driver'"
	or  $driver = "";

    $self->queryValue("SELECT hostIndex from HOSTS where address LIKE '$host%' AND db ='$DB'$driver");
}
sub getIndexHost {
  my $self=shift;
  my $lfn=shift;
  $lfn=~ s{/?$}{/};
  my $options={bind_values=>[$lfn]};
  return $self->queryRow("SELECT hostIndex, tableName,lfn FROM INDEXTABLE where ? like concat(lfn, '%') order by length(lfn) desc limit 1", undef, $options);
}

sub getMaxHostIndex {
  my $self = shift;

  $self->queryValue("SELECT MAX(hostIndex) from HOSTS");
}

sub insertHost {
  my $self = shift;
  my $ind = shift;
  my $ho = shift;
  my $d = shift;
  my $driv = shift;
  my $organisation=shift;

  my $data={hostIndex=>$ind, address=>$ho, db=>$d, driver=>$driv};
  $organisation and $data->{organisation}=$organisation;
	
  $DEBUG and $self->debug(2,"In insertHost inserting new data");
  $self->insert("HOSTS",$data)
}

sub updateHost {
  my $self = shift;
  my $ind = shift
    or $self->{LOGGER}->error("Catalogue","In updateHost host index is missing")
      and return;
  my $set = shift;
  
  $DEBUG and $self->debug(2,"In updateHost updating host $ind");
  $self->update("HOSTS",$set,"hostIndex='$ind'")
}

sub deleteHost {
  my $self = shift;
  my $ind = shift
    or $self->{LOGGER}->error("Catalogue","In deleteHost host index is missing")
      and return;

  $DEBUG and $self->debug(2,"In deleteHost deleting host $ind");
  $self->delete("HOSTS","hostIndex='$ind'")
}

### Groups functions

sub getUserGroups {
  my $self = shift;
  my $user = shift
    or $self->{LOGGER}->error("Catalogue","In getUserGroups user is missing")
      and return;
  my $prim = shift;
  defined $prim or $prim=1;

  $DEBUG and $self->debug(2,"In getUserGroups fetching groups for user $user");
  $self->queryColumn("SELECT groupname,userId from GROUPS where Username='$user' and PrimaryGroup = $prim");
}


sub getAllFromGroups {
	my $self=shift;
	my $attr = shift || "*";

	$DEBUG and $self->debug(2,"In getAllFromGroups fetching attributes $attr for all tuples from GROUPS table");
	$self->query("SELECT $attr FROM GROUPS");
}

sub insertIntoGroups {
  my $self = shift;
  my $user = shift;
  my $group = shift;
  my $var = shift;
  
  $DEBUG and $self->debug(2,"In insertIntoGroups inserting new data");
  $self->_do("INSERT IGNORE INTO GROUPS (Username, Groupname, PrimaryGroup) values ('$user','$group','$var')");
}

sub deleteUser {
  my $self = shift;
  my $user = shift
    or $self->{LOGGER}->error("Catalogue","In deleteUser user is missing")
      and return;
  
  $DEBUG and $self->debug(2,"In deleteUser deleting entries with user $user from GROUPS table");
  $self->delete("GROUPS","Username='$user'");
}



###	Environment functions

sub insertEnv {
  my $self = shift;
  my $user = shift
    or $self->{LOGGER}->error("Catalogue","In insertEnv user is missing")
      and return;
  my $curpath = shift
    or $self->{LOGGER}->error("Catalogue","In insertEnv current path is missing")
      and return;
  
  $DEBUG and $self->debug(2,"In insertEnv deleting old environment");
  $self->delete("ENVIRONMENT","userName='$user'") 
    or $self->{LOGGER}->error("Catalogue", "Cannot delete old environment")
      and return;
  
  $DEBUG and $self->debug(2,"In insertEnv inserting new environment");
  $self->insert("ENVIRONMENT",{userName=>$user,env=>"pwd $curpath"})
    or $self->{LOGGER}->error("Catalogue", "Cannot insert new environment")
      and return;

  1;
}

sub getEnv {
  my $self = shift;
  my $user = shift
    or $self->{LOGGER}->error("Catalogue","In getEnv user is missing")
      and return;

  $DEBUG and $self->debug(2,"In insertEnv fetching environment for user $user");
  $self->queryValue("SELECT env FROM ENVIRONMENT WHERE userName='$user'");
}

#	TAG functions

# quite complicated manoeuvers in Catalogue/Tag.pm - f_addTagValue
# difficult to merge with the others
#sub insertDirtagVarsFileValuesNew {
sub insertTagValue {
  my $self = shift;
  my $action= shift;
  my $path = shift;
  my $tag = shift;
  my $file = shift;
  my $rdata = shift;
  
  my $tableName = $self->getTagTableName($path, $tag);
  
  my $fileName = "$path$file";
  
#  $tableName =~ /T[0-9]+V$tag$/ or $fileName="$path$fileName";
  
  my $finished = 0;
  my $result;
  if ($action eq "update") {
    $self->info( "We want to update the latest entry (if it exists)");
    my $maxEntryId = $self->queryValue("SELECT MAX(entryId) FROM $tableName where file=?", 
				       undef, {bind_values=>[$fileName]});
    $DEBUG and $self->debug(2, "Got $maxEntryId");
    
    if ($maxEntryId) {
      $DEBUG and $self->debug(2, "WE ARE SUPPOSED TO ALTER THE ENTRY $maxEntryId");
      $result = $self->update($tableName, $rdata, "file='$fileName' and entryId=$maxEntryId");
      $finished = 1;
    }
  }

  if (!$finished) {
    $DEBUG and $self->debug(2, "Ok, we have to add the entry");


    $rdata->{file} = $fileName;
    my @keys=keys %{$rdata};
    $self->info( "We have $rdata and @keys");
    $result = $self->insert($tableName, $rdata);
    if ($result) {
      $self->info( "Let's make sure that we only have one entry");
      $self->delete($tableName, "file='$fileName' and entryId<".$self->getLastId());
    }
  }

  return $result;
}

sub getTags {
  my $self = shift;
  my $directory = shift;
  my $tag = shift;

  my $tableName = $self->getTagTableName($directory, $tag)
    or $self->info("In getFieldsFromTagEx table name is missing")
      and return;

  my $columns = shift || "*";
  my $where = shift || "";
  my $options=shift || {};
  my $query="SELECT $columns from $tableName where $where";
  if ($options->{filename}){
    $query.=" and entryId=(select max(entryId) from $tableName where file=?)";
    my @list=();
    $options->{bind_values} and @list=@{$options->{bind_values}};
    push @list, $options->{filename};
    $options->{bind_values}=\@list;

  }
  return $self->query($query, undef, $options);
}

sub getTagNamesByPath {
  my $self = shift;
  my $path = shift;
  
  $self->queryColumn("SELECT tagName from TAG0 where path='$path'");
}

sub getAllTagNamesByPath {
  my $self = shift;
  my $path = shift;
  
  $self->query("SELECT tagName,path from TAG0 where path like '$path%' group by tagName");
}

sub getFieldsByTagName {
  my $self = shift;
  my $tagName = shift;
  my $fields = shift || "*";
  my $distinct = shift;
  my $directory = shift;
  
  my $sql = "SELECT ";
  $distinct and $sql .= "DISTINCT ";
  
  $sql.="  $fields FROM TAG0 WHERE tagName='$tagName'";
  $directory and  $sql.="";

  $self->query($sql);
}


sub getTagTableName {
  my $self=shift;
  my $path=shift;
  my $tag=shift;

  $self->queryValue("SELECT tableName from TAG0 where path=? and tagName=?",undef, 
		    {bind_values=>[$path, $tag]});
}

sub deleteTagTable {
  my $self=shift;
  my $tag=shift;
  my $path=shift;
  $DEBUG and $self->debug(2, "In deleteTagTable");

  my $done;
  my $tagTableName=$self->getTagTableName($path, $tag);
  $tagTableName or $self->info( "Error trying to delete the tag table of $path and $tag") and return 1;
  my $user=$self->{USER};
  $DEBUG and $self->debug(2, "Deleting entries from T${user}V$tag");
  my $query="DELETE FROM $tagTableName WHERE file like '$path%' and file not like '$path/%/%'";
  
  $self->_do($query);

  $done = $self->delete("TAG0","path='$path' and tagName='$tag'");
  $done and $DEBUG and $self->debug(2, "Done with $done");
  return $done;
}

sub insertIntoTag0 {
	my $self = shift;
	my $directory = shift;
	my $tagName = shift;
	my $tableName=shift;

	$self->insert("TAG0", {path => $directory, tagName => $tagName, tableName => $tableName});
}

=item getDiskUsage($lfn)

Gets the disk usage of an entry (either file or directory)

=cut

sub getDiskUsage {
  my $self=shift;
  my $lfn=shift;

  my $size=0;
  if ($lfn=~ m{/$}){
    $DEBUG and $self->debug(1, "Checking the diskusage of directory $lfn");
    my $hosts=$self->getHostsForEntry($lfn);
    my $sourceInfo=$self->getIndexHost($lfn);

    foreach my $entry (@$hosts){
      $DEBUG and $self->debug(1, "Checking in the table $entry->{hostIndex}");
      my $db=$self->reconnectToIndex( $entry->{hostIndex});
      $self=$db;
      my $partialSize=$self->queryValue ("SELECT sum(size) from D$entry->{tableName}L where lfn like '$lfn%'");
      $DEBUG and $self->debug(1, "Got size $partialSize");
      $size+=$partialSize;
    }
    my $db=$self->reconnectToIndex($sourceInfo->{hostIndex});
    $self=$db;
    
  } else {
    my $table="D$self->{INDEX_TABLENAME}->{name}L";
    $DEBUG and $self->debug(1, "Checking the diskusage of file $lfn");
    $size=$self->queryValue("SELECT size from $table where lfn='$lfn'");
  }
  
  return $size;
}

=item DropEmtpyDLTables

deletes the tables DL that are not being used

=cut

sub DropEmptyDLTables{
  my $self=shift;
  $self->info("Deleting the tables that are not being used");
  #updating the D0 of all the databases
  my ($hosts) = $self->getAllHosts("hostIndex");

  defined $hosts
    or return;
  my ( $oldHost, $oldDB, $oldDriver ) = ($self->{HOST}, $self->{DB}, $self->{DRIVER});
  my $tempHost;
  foreach $tempHost (@$hosts) {
    #my ( $ind, $ho, $d, $driv ) = split "###", $tempHost;
    my $db=$self->reconnectToIndex( $tempHost->{hostIndex} );
    $self=$db;

    my $tables=$self->queryColumn("show tables like 'D\%L'") or print STDERR "Warning: error connecting to $tempHost->{hostIndex}" and next;
    foreach my $t (@$tables) {
      
      $self->info("Checking $t");
      $t=~ /^D(\d+)L$/ or $self->info("skipping...") and next;
      my $number=$1;
      my $n=$self->queryValue("select count(*) from $t") and next;
      $self->info("We have to drop $t!! (there are $n in $t)");
      my $indexes=$self->queryColumn("SELECT lfn from INDEXTABLE where tableName=$number and hostIndex=$tempHost->{hostIndex}");
      if ($indexes) {
	foreach my $i (@$indexes) {
	  $self->info("Deleting index $i");
	  $self->deleteFromIndex($i);
	}
      }
      $self->do("DROP TABLE $t");

    }

  }

  $DEBUG and $self->debug(2, "Everything is done!!");

  return 1;

}

=item executeInAllDB ($method, @args)

This subroutine calls $method in all the databases that belong to the catalogue
If any of the calls fail, it returns udnef. Otherwise, it returns 1, and a list of the return of all the statements. 

At the end, it reconnects to the initial database

=cut

sub executeInAllDB{
  my $self=shift;
  my $method=shift;


  $DEBUG and $self->debug(1, "Executing $method (@_) in all the databases");
  my $hosts=$self->getAllHosts("hostIndex");
  my ( $oldHost, $oldDB, $oldDriver) = 
    ($self->{HOST}, $self->{DB}, $self->{DRIVER});

  my $error=0;
  my @return;
  foreach my $entry (@$hosts){
    $DEBUG and $self->debug(1, "Checking in the table $entry->{hostIndex}");
    my $db=$self->reconnectToIndex( $entry->{hostIndex});
    if (!$db){
      $error=1;
      last;
    }

    my $info=$db->$method(@_);
    if (!$info) {
      $error=1;
      last;
    }
    push @return, $info;
  }

  $error and return;
  $DEBUG and $self->debug(1, "Executing in all databases worked!! :) ");
  return 1, @return;

}


sub selectDatabase {
  my $self=shift;
  my $path=shift;

  #First, let's check the length of the lfn that matches
  my $entry=$self->getIndexHost($path);
  $entry or  $self->info("The path $path is not in the catalogue ") and return;

  my $index=$entry->{hostIndex};
  my $tableName="L$entry->{tableName}L";
  if ( !$index ) {
    $DEBUG and $self->debug(1, "Error no index!! SELECT hostIndex from D0 where path='$path'");
    return;
  }
  $DEBUG and $self->debug(1, "We want to contact $index  and we are  $self->{CURHOSTID}");
  
  my $db=$self->reconnectToIndex($index, $path) or return;

  $db->setIndexTable($tableName, $entry->{lfn});
  return $db;
}
sub reconnectToIndex {
  my $self=shift;
  my $index=shift;
  my $path=shift;
  # we can send the info from the call, so that we skip one database query
  my $data=shift;
  ($index eq $self->{CURHOSTID}) and return $self;

  $data or 
    ($data) = $self->getFieldsFromHosts($index,"organisation,address,db,driver");
  ## add db error message
  defined $data
    or return;
  
  %$data or $self->info("Host with index $index doesn't exists")
      and return;

  $data->{organisation} or $data->{organisation}=$self->{CONFIG}->{ORG_NAME};
  my $dbindex="$self->{CONFIG}->{ORG_NAME}_$index";
  my $changeOrg=0;
  $DEBUG and $self->debug(1, "We are in org $self->{CONFIG}->{ORG_NAME} and want to contact $data->{organisation}");
  if ($path and ($data->{organisation} ne $self->{CONFIG}->{ORG_NAME})) {
    $self->info("We are connecting to a different organisation");
    $self->{CONFIG}=$self->{CONFIG}->Reload({organisation=>$data->{organisation}});
    $self->{CONFIG} or $self->info("Error getting the new configuration") and return;
    $path =~ s/\/$//;
    $self->{"MOUNT_$data->{organisation}"}=$path;
    
    $self->{MOUNT}.=$self->{"MOUNT_$data->{organisation}"};
    $self->info("Mount point:$self->{MOUNT}");
    $changeOrg=1;
  }

  if ( !$Connections{$self->{UNIQUE_NM}}->{$dbindex} ) {
    #    if ( !$self->{"DATABASE_$index"} ) {
    $DEBUG and $self->debug(1,"Connecting for the first time to $data->{address} $data->{db}" );
    # CHECK LOGGER!!
    my $DBOptions={
		   "DB"     => $data->{db},
		   "HOST"   => $data->{address},
		   "DRIVER" => $data->{driver},
		   "DEBUG"  => $self->{DEBUG},
		   "USER"   => $self->{USER},
		   "SILENT" => 1,
		   "TOKEN"  => $self->{TOKEN},
		   "LOGGER" => $self->{LOGGER},
		   "ROLE"   => $self->{ROLE},
		   "FORCED_AUTH_METHOD" => $self->{FORCED_AUTH_METHOD},
		   "UNIQUE_NM"=>$self->{UNIQUE_NM},
		  };
    $self->{PASSWD} and $DBOptions->{PASSWD}=$self->{PASSWD};
    defined $self->{USE_PROXY} and $DBOptions->{USE_PROXY}=$self->{USE_PROXY};

    AliEn::Database::Catalogue::LFN->new($DBOptions )
	or print STDERR "ERROR GETTING THE NEW DATABASE\n" and return;

    if ($changeOrg) {
      #In the new organisation, the index is different
      my ($newIndex)= $Connections{$self->{UNIQUE_NM}}->{$dbindex}->getHostIndex($data->{address}, $data->{db});
      $DEBUG and $self->debug(1, "Setting the new index to $newIndex");
      $self->{"DATABASE_$data->{organisation}_$newIndex"}=$self->{DATABASE};
      $DEBUG and $self->debug(1, "We should do selectDatabase again");
    }
  }
  $self->info("THE CONNECTION HAS BEEN CREATED PROPERLY!!!\n\n");
  return  $Connections{$self->{UNIQUE_NM}}->{$dbindex};
}

sub getLFNfromGUID {
  my $self=shift;
  my $guid=shift;
  my @lfns;

  my $entries=$self->query("select lfn,tableName,hostIndex from INDEXTABLE");
  foreach my $entry (@$entries){
    $DEBUG and $self->debug(1, "Checking in the table $entry->{hostIndex}");
    my $db=$self->reconnectToIndex( $entry->{hostIndex}) or next;
    my $paths = $db->queryColumn("SELECT concat('$entry->{lfn}',lfn) FROM L$entry->{tableName}L WHERE guid=string2binary(?) ", undef, {bind_values=>[$guid]});
    $paths and push @lfns, @$paths;
  }

  return @lfns;
}

sub getPathPrefix{
  my $self=shift;
  my $table=shift;
  my $host=shift;
  $table=~ s{^D(\d+)L}{$1};
  return $self->queryValue("SELECT lfn from INDEXTABLE where tableName='$table' and hostIndex='$host'");
}

sub findLFN() {
  my $self=shift;
  my ($path, $file, $refNames, $refQueries,$refUnions, %options)=@_;

  #first, let's take a look at the host that we want

  my $rhosts=$self->getHostsForEntry($path) or 
    $self->info( "Error getting the hosts for '$path'") and return;

  my @result=();
  my @done=();
  foreach my $rhost (@$rhosts) {
    my $id="$rhost->{hostIndex}:$rhost->{tableName}";
    grep (/^$id$/, @done) and next;
    push @done, $id;
    my $localpath=$rhost->{lfn};

    $DEBUG and $self->debug(1, "Looking in database $id (path $path)");

    my $db=$self->reconnectToIndex( $rhost->{hostIndex}, "", );
    $db or $self->info( "Error connecting to $id ($path)") and next;
    $DEBUG and $self->debug(1, "Doing the query");

    push @result, $db->internalQuery($rhost,$path, $file, $refNames, $refQueries, $refUnions, \%options);
  }
  return \@result;
}

# This subroutine looks for files that satisfy certain criteria in the 
# current database.
# Input:
#    $path: directory where the 'find' started'
#    $name: name of files that we are looking for
#    $refNames: reference to a list of paths with the tags
#    $refQueries: reference to a list of queries of metadata"
#    $refunion: reference to a list of unions between the queries
#    $options: d->return also the directories
# Output:
#    list of file that satisfy all the criteria
sub internalQuery {
  my $self=shift;
  my $refTable=shift;
  my $path=shift;
  my $file=shift;

  my $refNames=shift;
  my $refQueries=shift;
  my $refUnions=shift;
  my $options=shift;

  my $indexTable="L$refTable->{tableName}L";
  my $indexLFN=$refTable->{lfn};
  my @tagNames=@{$refNames};
  my @tagQueries=@{$refQueries};
  my @unions=("and", @{$refUnions});

  my @paths=();
  my @queries=();

  my @dirresults;

  my @joinQueries;

  if ($file ne "\\" ) {
      @joinQueries = ("WHERE concat('$refTable->{lfn}', lfn) LIKE '$path%$file%' and replicated=0");
      $options->{d} or $joinQueries[0].=" and lfn not like '%/' and lfn!= \"\"";
  } else {
      # query an exact file name
      @joinQueries = ("WHERE concat('$refTable->{lfn}', lfn)='$path'");
  }

  #First, let's construct the sql statements that will select all the files 
  # that we want. 
  my $tagsDone={};
  foreach my $tagName (@tagNames) {
    my $union=shift @unions;
    my $query=shift @tagQueries;
    my @newQueries=();

    if ($tagsDone->{$tagName}){
      $self->info("The tag $tagName has already been selected. Just add the constraint");
      foreach my $oldQuery (@joinQueries){
	push @newQueries, "$oldQuery $union $query";
      }
    }
    else {
      $DEBUG and $self->debug(1, "Selecting directories with tag $tagName");
      #Checking which directories have that tag defined
      my $tables = $self->getFieldsByTagName($tagName, "tableName", 1);
      $tables and $#{$tables} != -1
	or $self->info( "Error: there are no directories with tag $tagName in $self->{DATABASE}->{DB}") 
	  and return;
      foreach  (@$tables) {
	my $table=$_->{tableName};
	$self->debug(1, "Doing the new table $table");
	foreach my $oldQuery (@joinQueries) {
	  #This is the query that will get all the results. We do a join between 
	  #the D0 table, and the one with the metadata. There will be two queries
	  #like these per table with that metadata. 
	  #The first query gets files under directories with that metadata. 
	  # It is slow, since it has to do string comperation
	  #The second query gets files with that metadata. 
	  # (this part is pretty fast)
	  push @newQueries, " JOIN $table $oldQuery $union $table.$query and $table.file like '%/' and concat('$refTable->{lfn}', $indexTable.lfn) like concat( $table.file,'%') ";
	  push @newQueries, " JOIN $table $oldQuery $union $table.$query and concat('$refTable->{lfn}',$indexTable.lfn)= $table.file ";
	}
      }
    }
    @joinQueries=@newQueries;
    $tagsDone->{$tagName}=1;
  }
  my $order=" ORDER BY lfn";
  my $limit="";
  $options->{'s'} and $order="";
  $options->{l} and $limit = "limit $options->{l}";
  map {s/^(.*)$/SELECT *,concat('$refTable->{lfn}', lfn) as lfn,binary2string(guid) as guid from $indexTable $1 $order $limit/} @joinQueries;

  $self->debug(1,"We have to do $#joinQueries +1 to find out all the entries");

  #Finally, let's do all the queries:
  my @result;
  foreach (@joinQueries) {
    $DEBUG and $self->debug(1, "Doing the query $_");
    my $query=$self->query($_);
    push @result, @$query;
  }
  return @result;

}

sub setExpire{
  my $self=shift;
  my $lfn=shift;
  my $seconds=shift;
  defined $seconds or $seconds="";
  my $table=$self->{INDEX_TABLENAME}->{name};
  $lfn=~ s{^$self->{INDEX_TABLENAME}->{lfn}}{};

  my $expire="now()+$seconds";
  if ($seconds =~ /^-1$/){
    $expire="null";
  }else {
    $seconds=~ /^\d+$/ or 
      $self->info("The number of seconds ('$seconds') is not a number") 
	and return;
  }
  return $self->update($table, {expiretime=>$expire}, "lfn='$lfn'", {noquotes=>1});
}


sub destroy {
  my $self=shift;

  my ($number, $rest)=keys %Connections;
  $number or return;
  my @databases=keys %{$Connections{$number}};

  foreach my $database (@databases){
    $database=~ /^FIRST_DB$/ and next;
    $Connections{$number}->{$database} and $Connections{$number}->{$database}->SUPER::destroy();
    delete $Connections{$number}->{$database};
  }
  undef %Connections;

#  $self->SUPER::destroy();
}


sub getAllReplicatedData{
  my $self=shift;

  my $rusers = $self->getAllFromGroups("Username,Groupname,PrimaryGroup");
  defined $rusers
    or $self->info("Error: not possible to get all users")
      and return;

  my $rindexes =$self->getAllIndexes()  
    or $self->info( "Error: not possible to get mount points")
      and return;

  my $rses=$self->query("SELECT * from SE") or return;

  my $rhosts = $self->getAllHosts();
  defined $rhosts
    or $self->info("Error: not possible to get all hosts")
      and return;

  return {hosts=> $rhosts, users=>$rusers, indexes=>$rindexes, se=>$rses};
}

sub setAllReplicatedData {
  my $self=shift;
  my $info=shift;
  
  $info->{hosts} or $self->info("Error missing the hosts") and return;
  $info->{indexes} or $self->info("Error missing the hosts") and return;
  $info->{users} or $self->info("Error missing the hosts") and return;
  $info->{se} or $self->info("Error missing the hosts") and return;
  #First, all the hosts in HOSTS
  foreach my $rtempHost (@{$info->{hosts}}) {
      $self->insertHost($rtempHost->{hostIndex}, $rtempHost->{address}, $rtempHost->{db}, $rtempHost->{driver});
    }
  #Now, we should enter the data of D0
  foreach my $rdir (@{$info->{indexes}}) {
    $self->debug(1, "Inserting an entry in INDEXES");
    $self->do("INSERT INTO INDEXTABLE (hostIndex, tableName, lfn) values('$rdir->{hostIndex}', '$rdir->{tableName}', '$rdir->{lfn}')");
  }
    
    #Also, GROUPS table;
  foreach my $ruser (@{$info->{users}}) {
    $self->debug(1, "Adding a new user");
    $self->insertIntoGroups($ruser->{Username}, $ruser->{Groupname}, $ruser->{PrimaryGroup});
  }

    #and finally, the SE
  foreach my $se (@{$info->{se}}) {
    $self->debug(1, "Adding a new user");
    $self->insert("SE", $se);
  }
  return 1;
}

sub printConnections{
  my $self=shift;
  print "DE MOMENTO TENEMOS ". join (" ",  keys( %Connections)). "\n\n";
  print "Y BASES ". join (" ", keys (%{$Connections{$self->{UNIQUE_NM}}})). "\n\n";
}


=head1 SEE ALSO

AliEn::Database

=cut

1;

