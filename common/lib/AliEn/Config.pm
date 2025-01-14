package AliEn::Config;
use strict;

#use IO::Socket;
use Net::LDAP;
use AliEn::Logger::LogObject;
use Net::Domain;
use AliEn::Util;

use vars qw(@ISA $DEBUG);
push @ISA, "AliEn::Logger::LogObject";
my $self;
$DEBUG = 0;
my $organisations = {};
my @SERVICES      = ("SE", "CE", "FTD", "PackMan", "MonaLisa", "ApiService");

sub new {
  my $proto = shift;
  defined $self and return $self;
  return (Initialize($proto, @_));
}

sub DESTROY {
  undef $self;
}

sub Reload {
  my $t       = shift;
  my $options = shift;
  $DEBUG and $self and $self->debug(1, "Reloading the configuration");
  $t->Initialize($options);
}

sub Initialize {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $temp  = shift || {};
  umask 027;
  my $organisation = "Alice";
  $ENV{ALIEN_ORGANISATION} and $organisation = $ENV{ALIEN_ORGANISATION};
  $temp->{organisation}    and $organisation = $temp->{organisation};
  my $organisationLowerCase = "\L$organisation\E";
  $temp->{DEBUG}  or $temp->{DEBUG}  = 0;
  $temp->{SILENT} or $temp->{SILENT} = 0;
  $temp->{silent} and $temp->{SILENT} = $temp->{silent};
  $temp->{debug}  and $temp->{DEBUG}  = $temp->{debug};
  (!$temp->{SILENT})
	and ($temp->{DEBUG} > 0)
	and print "DEBUG LEVEL 1. Checking config for $organisationLowerCase\n";

  if ($organisations->{$organisationLowerCase}) {

	#      	$self->debug(1, " Configuration already exists!!");
	$self = $organisations->{$organisationLowerCase};
	$temp->{force} or return $self;
	$self->debug(1, "Forcing to reload the configuration");
  }
  (!$temp->{SILENT})
	and ($temp->{DEBUG} > 0)
	and print "DEBUG LEVEL 1. Getting config for $organisationLowerCase\n";
  bless($temp, $class);
  $temp->SUPER::new({logfile => $temp->{logfile}}) or return;
  (defined $ENV{ALIEN_DOMAIN})
	or $ENV{ALIEN_DOMAIN} = Net::Domain::hostdomain();
  $temp->{DOMAIN} = $ENV{ALIEN_DOMAIN}; 
  (defined $ENV{ALIEN_HOSTNAME})
	or $ENV{ALIEN_HOSTNAME} = Net::Domain::hostfqdn();
  $temp->{HOST} = $ENV{ALIEN_HOSTNAME};
  $organisations->{$organisationLowerCase} = $temp;

  #I'm not sure why we need this undef...
  #however, if it is not there, sometimes the assignment doesn't work
  undef $self;
  $self = $temp;

  #    print "IN CONFIG, we have $self->{HOST}\n";
  $self->{DEBUG}  and $self->{LOGGER}->debugOn($self->{DEBUG});
  $self->{SILENT} and $self->{LOGGER}->silentOn();
  my $done = 0;
  if ($ENV{ALIEN_CM_AS_LDAP_PROXY}) {
	my $d = $self->GetConfigFromCM();
	if ($d) {
	  $self = $d;
	  $done = 1;
	}
  }
  if (!$done) {
	$self->debug(1, "Getting the configuration from the LDAP server");
	$self->{LOCAL_USER} = getpwuid($<);
	$ENV{ALIEN_USER} and $self->{LOCAL_USER} = $ENV{ALIEN_USER};
	$self->{ROLE} = $self->{LOCAL_USER};
	$self->{role} and $self->{ROLE} = $self->{role};
	$self->debug(1, "Config for user $self->{LOCAL_USER} ($self->{ROLE})");

	#    my $ldapConfig=$struct->{proxyport}[0];
	$self->{ORG_NAME} = "$organisation";
	my $ldap = $self->GetLDAPDN();
	$ldap                         or return;
	$self->GetOrganisation($ldap) or return;
	$self->GetSite($ldap)         or return;
	foreach my $service (@SERVICES) {
	  $self->GetServices($ldap, $service) or return;
	}
	$self->GetHostConfig($ldap) or return;
	if ($self->{queue}) {
	  $self->setService($ldap, $self->{queue}, "CE") or return;
	}
	$self->GetTopLevelServices($ldap) or return;
	if ( $self->{LOCAL_CONFIG}
	  && $self->{LOCAL_CONFIG} =~ /^(add)|(overwrite)$/i) {
	  $self->checkConfigFile(
		"$ENV{ALIEN_ROOT}/etc/alien/$self->{ORG_NAME}.conf",
		"/etc/alien/$self->{ORG_NAME}.conf",
		"$ENV{ALIEN_HOME}/\L$self->{ORG_NAME}\E.conf"
	  );
	}
	$self->GetGridPartition($ldap) or return;
	$ldap->unbind;    # take down session
  }
  return $self->checkVariables();
}

sub checkVariables {
  my $self = shift;
  $self->debug(1, "Checking if we can write to the directories");
  for my $entry ("TMP_DIR", "LOG_DIR", "CACHE_DIR", "WORK_DIR", "WORKDIR") {
	$self->{$entry} or next;
	$self->debug(1, "Checking $entry => $self->{$entry}");
	if ($self->{$entry} =~ /\$/) {
	  $self->{"${entry}_ORIG"} = $self->{$entry};
	}
	while ($self->{$entry} =~ s{\$([^/]*)}{$ENV{$1}}) {
	  $self->debug(1, "Replacing $1 by  $ENV{$1} in $entry");
	}
	my $ok = AliEn::Util::mkdir($self->{$entry});
	if ($ok) {
	  system("touch $self->{$entry}/alien_test.$<") and $ok = 0;
	  unlink("$self->{$entry}/alien_test.$<");
	  $ok and next;
	}
	$self->debug(1,
"Warning!! We are supposed to use $self->{$entry} ans $entry, but we can't write there. Changing it to /tmp/alien_auto_$</$entry"
	);
	$self->{$entry} = "/tmp/alien_auto_$</$entry";
	AliEn::Util::mkdir($self->{$entry});
  }
  return $self;
}

sub checkConfigFile {
  my $self = shift;
  my $config;
  my $mode = $self->{LOCAL_CONFIG};
  $self->debug(1, "Reading the local configuration (and $mode)");
  foreach my $file (@_) {
	(-f $file) or next;
	$self->info("Reading the configuration file from $file");
	eval {
	  require Config::ApacheFormat;
	  $config or $config = Config::ApacheFormat->new();
	  $config->read($file);
	};
	if ($@) {
	  $self->info("Error reading the config file $file: $@");
	  return;
	}
  }

  #if there are no configuration files, just return;
  $config or return 1;

  #check if there are any services defined
  foreach my $service (@SERVICES) {
	my @blocks = $config->get($service);
	$mode =~ /add/
	  and $self->info("The local configuration is not allowed to define services")
	  and next;
	foreach my $d (@blocks) {
	  my $name = ${$d}[1];
	  $name
		or print "Warning! the service $service doesn't have any names (ignoring it)\n"
		and next;
	  $DEBUG
		and $self->debug(2, "Defining the service $service ${$d}[0] and ${$d}[1]");
	  $self->{$service} = $name;
	  foreach (grep (/^${service}_/i, keys %$self)) {
		delete $self->{$_};
	  }
	  my $SER = uc($service);
	  $self->{"${SER}_NAME"}     = $name;
	  $self->{"${SER}_FULLNAME"} = "$self->{ORG_NAME}::$self->{SITE}::$name";
	  my $subconfig = $config->block($d);
	  foreach my $subkey ($subconfig->get) {
		my $name = "${SER}_\U$subkey\E";
		$DEBUG and $self->debug(5, "Setting $subkey (in $name)");
		$self->{$name} = $subconfig->get($subkey);
		my @list = $subconfig->get($subkey);
		$self->{"${name}_LIST"} = \@list;
	  }
	  $DEBUG and $self->debug(2, "Service $service ${$d}[0] defined");
	}
  }

  #  return 1;
  #now, we should go through all the things defined in the config...
  foreach ($config->get()) {
	my $key = uc($_);
	$DEBUG and $self->debug(2, "\t\tChecking the value '$key'");
	if (grep (/^$key$/, @SERVICES)) {
	  $DEBUG
		and $self->debug(2, "Ignoring the block '$key' from the configuration file");
	  next;
	}
	my $block;
	eval {
	  my $subconfig = $config->block($key);
	  $self->info("Ignoring the block $key");
	  $block = 1;
	};
	$block and next;
	$DEBUG and $self->debug(3, "Overwritten the value '$key'");
	$self->{$key}
	  or $self->info("The local configuration defines '$key="
		. $config->get($key)
		. "' (a variable that is not in the standard configuration)");
	($mode =~ /add/i)
	  and $self->{$key}
	  and $self->info("The local configuration is not allowed to override $key")
	  and next;
	$self->{$key} = $config->get($key);
	my @list = $config->get($key);
	$self->{"${key}_LIST"} = \@list;
  }
  return 1;
}

sub getVOLDAPfromFile {
  my $self = shift;
  my $time = shift;
  my $vo   = $self->{ORG_NAME};
  my $file = "$ENV{ALIEN_HOME}/.lastLDAP.$vo";
  (-f $file) or return;
  if ($time) {
	$self->debug(1, "Checking that the file is not older than $time seconds");
	my @info = stat $file;
	my $now  = time;
	($now - $time) > $info[9] and return;
  }
  open(FILE, "<$file") or return;
  my $info = join("", <FILE>);
  close FILE;
  chomp $info;
  $info =~ s{\s*}{}m;
  my ($host, $dn) = split("/", $info);
  $self->debug(1, "Returning '$host' and '$dn' from the localfile '$file'");
  return ($host, $dn);
}

sub getVOLDAP {
  my $self = shift;
  my ($host, $dn);
  if ($ENV{ALIEN_LDAP_DN}) {
	$self->debug(1, "Getting the Config from $ENV{ALIEN_LDAP_DN}");
	($host, $dn) = split("/", "$ENV{ALIEN_LDAP_DN}");
	$ENV{ALIEN_LDAP_DN} =~ /o=$self->{ORG_NAME},/i
	  or $self->info(
"We are supposed to get the configuration from ALIEN_LDAP_DN=$ENV{ALIEN_LDAP_DN}, but this doesn't look like our organisation $self->{ORG_NAME})"
	  )
	  and return;
	return ($host, $dn);
  }
  ($host, $dn) = $self->getVOLDAPfromFile(43200);
  $host and return ($host, $dn);
  eval {
	my $ldap = Net::LDAP->new('alien.cern.ch:8389') or die "$@";
	my $base = "o=alien,dc=cern,dc=ch";
	$DEBUG
	  and $self->debug(1, "Getting the Config of $self->{ORG_NAME} from $base");
	$ldap->bind;    # an anonymous bind
	my $mesg = $ldap->search(    # perform a search
	  base   => "$base",
	  filter => "(ou=$self->{ORG_NAME})"
	);
	$mesg->code && die $mesg->error;
	my $total = $mesg->count;
	if (!$total) {
	  print STDERR "ERROR: There are no organisations called '$self->{ORG_NAME}'\n";
	  return;
	}
	my $entry    = $mesg->entry(0);
	my $ldaphost = $entry->get_value('ldaphost');
	$ldaphost =~ s/\s+$//;
	$host = $ldaphost;
	$dn   = $entry->get_value('ldapdn');
	$ldap->unbind;    # take down session
  };
  if ($@) {
	$self->info("Error contacting the ldap at 'alien.cern.ch': $@");
  }
  if ($host) {
	$self->debug(1, "We got the info from the ldap. Let's update the file");
	if (open(FILE, ">$ENV{ALIEN_HOME}/.lastLDAP.$self->{ORG_NAME}")) {
	  print FILE "$host/$dn\n";
	  close FILE;
	}
	return ($host, $dn);
  }
  return $self->getVOLDAPfromFile();
}

sub GetLDAPDN {
  my $self = shift;
  ($self->{LDAPHOST}, $self->{LDAPDN}) = $self->getVOLDAP() or return;
  $DEBUG and $self->debug(1, "Connecting to $self->{LDAPHOST}");
  my $ldap = Net::LDAP->new($self->{LDAPHOST})
	or die "Error contacting LDAP in $self->{LDAPHOST}\n $@\n";
  $ldap->bind;    # an anonymous bind
  return $ldap;
}

sub GetGridPartition {
  my $self = shift;
  my $ldap = shift;
  $self->debug(1, "Getting the grid partition!");
  if (!$self->{CE_NAME}) {
	$self->debug(1, "The machine does not have a CE");
	return 1;
  }
  my $filter = "(&(objectClass=AliEnPartition)(CEname=$self->{CE_FULLNAME}))";
  my $base   = "ou=Partitions,$self->{LDAPDN}";
  my $mesg   = $ldap->search(                                                    # perform a search
	base   => "$base",
	filter => "$filter"
  );
  my $total = $mesg->count;
  if (!$total) {
	$self->debug(1, "The machine $self->{CE_FULLNAME} does not belong to any Grid Partition");
	return 1;
  }
  my @list = ();
  my $i    = 0;
  while ($i < $total) {
	my $name = $mesg->entry($i)->get_value('name');
	$self->debug(1, "PARTITITON $name");
	@list = (@list, $name);
	$i++;
  }
  $self->{GRID_PARTITION}      = $list[0];
  $self->{GRID_PARTITION_LIST} = \@list;
  return 1;
}

sub GetSite {
  my $self   = shift;
  my $ldap   = shift;
  my $domain = $ENV{ALIEN_CONFIG_DOMAIN} || $ENV{ALIEN_DOMAIN};
  $DEBUG and $self->debug(1, "Configuring the site $domain");
  my $mesg = $ldap->search(    # perform a search
	base   => "ou=Sites,$self->{LDAPDN}",
	filter => "(&(domain=$domain)(objectClass=AliEnSite))"
  );
  my $total = $mesg->count;
  if (!$total) {
	print STDERR "ERROR: There are no sites in $self->{ORG_NAME} with domain $domain\n";
	return;
  }
  if ($total > 1) {
	(!$self->{SILENT})
	  and print STDERR "Warning: There are more than one site with domain $domain\n Taking the first one :"
	  . $mesg->entry(0)->get_value('ou')
	  . " (there is also "
	  . $mesg->entry(1)->get_value('ou') . ")\n";
  }
  my $entry   = $mesg->entry(0);
  my $entries = {
	LOG_DIR            => 'logdir',
	TMP_DIR            => 'tmpdir',
	SITE_LATITUDE      => 'latitude',
	SITE_LONGITUDE     => 'longitude',
	SITE_LOCATION      => 'location',
	SITE_ADMINISTRATOR => 'administrator',
	SITE_COUNTRY       => 'country',
	PACKMAN_ADDRESS    => 'packmanAddress',
	LOCAL_CONFIG       => 'localconfig',
	WORK_DIR           => 'workdir',
	DOMAIN             => 'domain',
	'SITE'             => 'ou',
  };
  foreach my $key (keys %$entries) {
	$self->{$key} = $entry->get_value($entries->{$key}) || "";
  }

  # Setting the Cache directory. First, home directory of the user
  $self->ChangeCacheDir($entry->get_value('cachedir'));
  $self->ChangeCacheDir($ENV{ALIEN_CACHE});
  $self->{CACHE_DIR}
	or $self->ChangeCacheDir("$ENV{ALIEN_HOME}/cache")
	or return;
  $self->{FULLLDAPDN} = "ou=$self->{SITE},ou=Sites,$self->{LDAPDN}";
  my $saveSE = ($entry->get_value('SaveSE') or "none");
  my @SaveSEs = ($entry->get_value('SaveSE'));
  $self->setService($ldap, $saveSE, "SaveSE", "SE") or return;
  $self->{SaveSEs_FULLNAME} = \@SaveSEs;

  #    my $package;
  my @list = $entry->get_value('packages');
  $self->{PACKAGES_LIST} = \@list;
  my @processPorts = $entry->get_value('processPorts');
  if (@processPorts) {
	$self->{PROCESS_PORT}      = $entry->get_value('processPorts');
	$self->{PROCESS_PORT_LIST} = \@processPorts;
  }
  $DEBUG and $self->debug(1, "$self->{SITE} configured!");
  my @closeSE = $entry->get_value('closese');
  my @newList;
  foreach my $se (@closeSE) {
	$self->info("Hello $se");

	#putting the name of the site
	$se =~ /::/ or $se = "$self->{SITE}::$se";

	#putting the vo
	$se =~ /::[^:]*::/ or $se = "$self->{ORG_NAME}::$se";
	push @newList, $se;
  }
  $self->{CLOSESE_LIST} = \@newList;
  return $self->checkVirtualSite($entry);
}

sub checkVirtualSite {
  my $self  = shift;
  my $entry = shift;
  $self->debug(1, "Checking if this is a virtual site");
  my $virtual = $entry->get_value("virtualSite");
  $virtual or return 1;
  $self->info("This is a virtual site of $virtual!!");
  my $name = "AliEn::Config::$virtual";
  eval "require $name"
	or $self->info("Error requiring the module $name: $@")
	and return;
  $self = bless($self, $name);
  return $self->ConfigureVirtualSite();
}

sub ChangeCacheDir {
  my $self     = shift;
  my $cachedir = shift;
  $cachedir or return;
  my $orig = $cachedir;
  $DEBUG and $self->debug(2, "Using $cachedir as Cache from the LDAP");
  $self->{CACHE_DIR_ORIG} = "$cachedir";
  while ($cachedir =~ s{\$([^/]*)}{$ENV{$1}}) {
	$self->debug(1, "Replacing $1 by  $ENV{$1}");
  }
  my $dbPath = "$cachedir/LCM.db";
  if (!(-d $dbPath)) {
	my $dir = "";
	foreach (split("/", $dbPath)) {
	  $self->debug(1, "Creating the directory $dir");
	  $dir .= "/$_";
	  mkdir($dir, 0777);
	}
  }
  my $exists = -e "$dbPath/LOCALFILES";
  open(FILE, ">>$dbPath/LOCALFILES")
	or print STDERR "Warning! not able to use  $cachedir as cache dir\n"
	and return;
  close(FILE);
  $exists or unlink "$dbPath/LOCALFILES";
  $self->{CACHE_DIR} = $cachedir;
  $self->{CACHE_DIR_ORIG} = $orig;
  return 1;
}

sub GetServices {
  my $self    = shift;
  my $ldap    = shift;
  my $service = shift;
  $DEBUG and $self->debug(4, "Getting ${service}s of site $self->{SITE}");
  my $base  = "ou=$service,ou=services,$self->{FULLLDAPDN}";
  my $class = "AliEn$service";
  $service eq "SE" and $class = "AliEnMSS";
  my $mesg = $ldap->search(    # perform a search
	base   => "$base",
	filter => "(&(objectClass=$class)(name=*))"
  );
  my $total = $mesg->count;
  if (!$total) {
	$self->debug(1, "Warning: no $service defined for your site");
	return 1;
  }
  my $entry   = $mesg->entry(0);
  my $name    = $entry->get_value('name');
  my $version = $entry->get_value('version');
  $self->{$service} = $name;
  $self->setService($ldap, $name, uc($service)) or return;
  my @list  = ($name);
  my @types = ($entry->get_value('type'));
  my $i     = 1;

  while ($i < $total) {
	@list  = (@list,  $mesg->entry($i)->get_value('name'));
	@types = (@types, $mesg->entry($i)->get_value('type'));
	$i++;
  }
  $self->{"\U${service}s\E"}      = \@list;
  $self->{"\U${service}s_TYPE\E"} = \@types;
  my @fullNames = @list;
  map { $_ = "$self->{ORG_NAME}::$self->{SITE}::$_" } @fullNames;
  $self->{"${service}s_FULLNAME"} = \@fullNames;
  $DEBUG
	and $self->{"${service}s"}
	and
	$self->debug(1, "ALL ${service}s are: " . @{$self->{"${service}s"}} . "\n\t\tDefault $service '$self->{$service}'");
  return 1;
}

sub GetOrganisation {
  my $self    = shift;
  my $ldap    = shift;
  my $VERSION = 1;
  $DEBUG and $self->debug(7, "Setting the organisation from $self->{LDAPDN}");
  if (-f "$ENV{ALIEN_ROOT}/share/alien/ALIEN_VERSION") {
	$DEBUG and $self->debug(5, "Getting the debug from the ALIEN_VERSION");
	open(FILE, "$ENV{ALIEN_ROOT}/share/alien/ALIEN_VERSION")
	  or $self->info("Error getting the version of alien!!")
	  and return;
	my @common = <FILE>;
	close(FILE);
	if (join("", @common) =~ /AliEn\s+(\S+),\s+build:\s*(\S+),/) {
	  $VERSION = "${1}.$2";
	} else {
	  $self->info("Error getting the version from $ENV{ALIEN_ROOT}/share/alien/ALIEN_VERSION (wrong format?)");
	  return;
	}
  } elsif (-d "$ENV{ALIEN_ROOT}/share/alien/packages/") {
	$DEBUG and $self->debug(5, "Getting the debug from the directory");
	opendir(DIR, "$ENV{ALIEN_ROOT}/share/alien/packages/")
	  or $self->info("Error getting the version of alien!!")
	  and return;
	my ($common) = grep (/alien-common/, readdir(DIR));
	closedir(DIR);
	$VERSION = $common;
	$VERSION =~ s/alien-common-//;
  } elsif (-f "$ENV{ALIEN_ROOT}/scripts/VERSION") {
	open VERSION, "$ENV{ALIEN_ROOT}/scripts/VERSION";
	my @lines = <VERSION>;
	close VERSION;
	foreach my $line (@lines) {
	  eval "\$$line";
	}
  } elsif (defined $ENV{ALIEN_VERSION}) {
	$VERSION = $ENV{ALIEN_VERSION};
  }
  $self->{VERSION} = $VERSION;
  $DEBUG and $self->debug(5, "Version $VERSION");
  my $mesg = $ldap->search(    # perform a search
	base   => "$self->{LDAPDN}",
	filter => "&(ou=Config)(objectClass=AliEnVOConfig) "
  );

  #    $struct = $mesg->as_struct->{"ou=Config,$ldapdn"};
  my $entry = $mesg->entry(0);
  $entry
	or print STDERR
	"Error getting the configuration for the organisation from host=$self->{LDAPHOST} and dn=$self->{LDAPDN}\n"
	and return;
  my $attr;
  foreach $attr ($entry->attributes) {
	my $value = $attr;
	$value =~ s/([A-Z])/_$1/g;
	$value = uc($value);
	$self->{$value} = $entry->get_value($attr);
	my @list = $entry->get_value($attr);
	$self->{"${value}_LIST"} = \@list;
	$DEBUG
	  and $self->debug(7, "Setting $value as ($attr)  " . $entry->get_value($attr) . " (@list)");
  }
  $DEBUG and $self->debug(7, "Organisation done!");
  return 1;
}

sub GetHostConfig {
  my $self   = shift;
  my $ldap   = shift;
  my $domain = $ENV{ALIEN_CONFIG_DOMAIN} || $ENV{ALIEN_DOMAIN};
  chomp $domain;
  $self->{domain} and $domain = $self->{domain};
  my $host = $ENV{'ALIEN_HOSTNAME'};
  chomp $host;
  $DEBUG and $self->debug(4, "Getting special configuration for $host");
  my $base = "ou=config,$self->{FULLLDAPDN}";
  my $mesg = $ldap->search(                     # perform a search
	base   => "$base",
	filter => "(host=$host)"
  );
  my $total = $mesg->count;
  if (!$total) {
	$self->debug(1, "No local configuration found. Using the default");
	return 1;
  }
  my $entry = $mesg->entry(0);
  $self->{SITE_HOST} = $entry->get_value('host');
  $self->debug(1, "Using the configuration of $self->{SITE_HOST}");
  my @variables     = ("logdir",  "tmpdir",  "cachedir",  "workdir", "localconfig");
  my @variablesName = ("LOG_DIR", "TMP_DIR", "CACHE_DIR", "WORKDIR", "LOCAL_CONFIG");
  foreach (@variables) {
	my $var  = $entry->get_value($_);
	my $name = shift @variablesName;
	if ($var) {
	  $self->debug(1, "Using another variable $_ : $var");
	  $self->{$name} = $var;
	}
  }
  my @serviceName = (@SERVICES, "SE");
  foreach (@SERVICES, "SaveSE") {
	my $name    = shift @serviceName;
	my $service = $entry->get_value($_);
	if ($service) {
	  $self->debug(1, "Using another $_ ($name): $service");
	  $self->setService($ldap, $service, $_, $name) or return;
	}
  }
  my @packages = $entry->get_value('Packages');
  if (@packages) {
	$self->{"HOST_PACKAGES_LIST"} = \@packages;
  }

  #Checking the close SE;
  my @se = $entry->get_value('CloseSE');
  if (@se) {
	$self->debug(1, "We should put @se as closeSE");
	my @seList    = ();
	my @fullNames = ();
	foreach my $serviceName (@se) {
	  my $se = $self->CheckService("SE", $serviceName, $ldap);
	  $se
		or $self->{LOGGER}
		->error("Config", "Error host  '$host' is supposed to be close to $serviceName, but that SE does not exist")
		and return;

	  #      print "GOT $se and $se->{FULLNAME}} and $se->{NAME}\n";
	  push @seList,    $se->{NAME};
	  push @fullNames, $se->{FULLNAME};
	}
	$self->{SEs}          = \@seList;
	$self->{SEs_FULLNAME} = \@fullNames;
  }
  $self->_setEnvironment($entry);
  $self->debug(1, "$self->{SITE_HOST} configured!!");
  return 1;
}

# Given a service name, this method retrieves all its data from the ldap
# and puts it in the config object.
#
#
sub setService {
  my $self        = shift;
  my $ldap        = shift;
  my $name        = shift;
  my $service     = shift;
  my $serviceName = (shift or $service);
  $self->debug(1, "Setting $service as $name !");
  my @all = grep (/^${service}_/, keys %{$self});
  map { delete $self->{$_} } @all;

  if ($name eq "none") {
	$self->{$service} = "";
	$self->{"${service}_FULLNAME"} = "";
	my @list = ();
	$self->{"${service}s_FULLNAME_LIST"} = @list;
	$self->debug(1, "Using no $service");
	return 1;
  }
  my $se = $self->CheckService($serviceName, $name, $ldap);
  $se or return;
  $service = uc($service);
  @all     = keys %{$se};
  map { $self->{$_} = undef } grep(/^${service}_/, keys(%$self));
  map { $self->{"${service}_$_"} = $se->{$_} } @all;
  $self->{$service} = $se->{NAME};
  $DEBUG and $self->debug(1, "Using $service $self->{$service}");
  $self->_setEnvironment($se);
  return 1;
}

#
# If the ldap entry has a field called 'Environment', this will set it up
sub _setEnvironment {
  my $self  = shift;
  my $entry = shift;
  my @env;
  eval { @env = $entry->get_value("Environment") };
  ($@)
	and $entry->{ENVIRONMENT_LIST}
	and push @env, @{$entry->{ENVIRONMENT_LIST}};
  foreach my $env (@env) {
	my ($key, $value) = split(/=/, $env, 2);
	$DEBUG and $self->debug(1, "Setting the env '$key' to '$value'");
	$ENV{$key} = $value;
  }
  return 1;
}

sub getValue {
  my $self  = shift;
  my $value = shift;
  return $self->{$value};
}

sub GetConfigFromCM {
  my $this = shift;
  $DEBUG
	and $this->debug(1, "Getting the configuration from the ClusterMonitor");
  my $CMaddress = $ENV{ALIEN_CM_AS_LDAP_PROXY};
  $CMaddress
	or print STDERR
"ERROR: The environment variable ALIEN_CM_AS_LDAP_PROXY was set ($ENV{ALIEN_CM_AS_LDAP_PROXY}), but not with a host:port syntax!!\n"
	and return;


  my $config;
  my $retry = 10;
  my $sleep = 10;

  while (1) {
	  eval {
	    my $d=AliEn::RPC->new();
	    $d->Connect("ClusterMonitor");
	    ($config)=$d->CallRPC("ClusterMonitor", "GetConfiguration");
	  };
	  if ($@) {
	    $self->info("It died: $@");
	    return;
	  }
	  $config and  last;
	  $retry--;
	  $this->info("Error contacting the ClusterMonitor");
	  if (!$retry) {
	    $this->info("We have retried enough times");
	    return;
	  }
	  $sleep = $sleep * 2 + int(rand(2));
	  $sleep = $sleep % 60;
	  $this->info("Sleeping $sleep seconds before trying again");
  	sleep($sleep);
  }
  $this->debug(1, "Got the config from the ClusterMonitor");
  (UNIVERSAL::isa($config, "HASH"))
	or print STDERR "Error the ClusterMonitor did not return a hash ($config)\n"
	and return;
  my $log;
  $this->{LOGGER}->{logfile} and $log = $this->{LOGGER}->{logfile};
  map {
	$DEBUG and $self->debug(6, "Setting $_ as $config->{$_}");
	$this->{$_} = $config->{$_}
  } (keys %$config);
  $log and $this->{LOGGER}->{logfile} = $log;
  $log or delete $this->{LOGGER}->{logfile};
  $DEBUG and $this->debug(1, "Getting the configuration done!");
  if (grep(/_ORIG$/, keys %$self)) {
	$self->debug(1, "There are some variables that we have to recover");
	foreach my $k (grep(/_ORIG$/, keys %$self)) {
	  my $j = $k;
	  $j =~ s/_ORIG$//;
	  $self->{$j} = $self->{$k};
	}
	$self->checkVariables();
  }
  $this->{DOMAIN} = $ENV{ALIEN_DOMAIN}   = Net::Domain::hostdomain();
  $this->{HOST}   = $ENV{ALIEN_HOSTNAME} = Net::Domain::hostfqdn();
  return $this;
}

sub CheckServiceCache {
  my $this    = shift;
  my $service = shift;
  my $name    = shift;
  $name or return;
  $self->{CACHE} or $self->{CACHE} = {};
  $self->{CACHE}->{$service} or $self->{CACHE}->{$service} = {};
        $self->{CACHE}->{$service}->{$name}
	and $self->{CACHE}->{$service}->{$name}->{expires}
	and $self->{CACHE}->{$service}->{$name}->{expires} > time()
	and return $self->{CACHE}->{$service}->{$name}->{value};
  $self->{CACHE}->{$service}->{$name}->{value} = $self->CheckService($service, $name, @_)
	or return;
  $self->{CACHE}->{$service}->{$name}->{expires} = time() + 600;
  return $self->{CACHE}->{$service}->{$name}->{value};
}

sub CheckUser {
  my $this       = shift;
  my $username   = shift;
  my $ldap       = shift || "";
  my $disconnect = 0;
  if (!$ldap) {
	$ldap = Net::LDAP->new($self->{LDAPHOST})
	  or print STDERR "Error contacting ldap: $@"
	  and return;
	$ldap->bind or print STDERR "Error binding to LDAP" and return;
	$disconnect = 1;
  }
  my $base   = "ou=People,$self->{LDAPDN}";
  my $filter = "(&(objectClass=AliEnUser)(uid=$username))";
  my $mesg   = $ldap->search(base => "$base", filter => "$filter");
  my $total  = $mesg->count;
  if (!$total) {
	$self->info("Couldn't find the user '$username'");
	return;
  }
  my $entry = $mesg->entry(0);
  $disconnect and $ldap->unbind;
  my $hash = {};
  foreach my $attr ($entry->attributes) {
	my $value = $entry->get_value($attr);
	my @list  = $entry->get_value($attr);
	$attr = uc($attr);
	$DEBUG
	  and $self->debug(7, "Putting $attr as $value\n\tAnd ${attr}_LIST=@list");
	$hash->{"$attr"}        = $value;
	$hash->{"${attr}_LIST"} = \@list;
  }
  return $hash;
}

sub CheckService {
  my $this       = shift;
  my $service    = shift;
  my $name       = shift;
  my $ldap       = (shift or "");
  my $disconnect = 0;
  if (!$ldap) {
	$ldap = Net::LDAP->new($self->{LDAPHOST})
	  or print STDERR "Error contacting ldap: $@"
	  and return;
	$ldap->bind or print STDERR "Error binding to LDAP" and return;
	$disconnect = 1;
  }
  $service =~ /^((SE)|(CE)|(FTD)|(PACKMAN)|(MONALISA)|(APISERVICE))$/i
	or print STDERR "Error service type $service does not exist\n"
	and return;
  ($name)
	or print STDERR "Error not enough arguments in CheckService\n"
	and return;
  my $se    = {};
  my $base  = "ou=$service,ou=services,$self->{FULLLDAPDN}";
  my $site  = $self->{SITE};
  my $class = "AliEn$service";
  $service =~ /^SE$/ and $class = "AliEnMSS";
  my $filter = "(&(objectClass=$class)(name=$name))";

  if ($name =~ /\:\:/) {
	$DEBUG
	  and $self->debug(1, "WE ARE USING ANOTHER $service from another site");
	my $org;
	($org, $site, $name) = split "::", $name;
	($org =~ /^$self->{ORG_NAME}$/i)
	  or print STDERR
	  "ERROR: You are trying to use a resource from $org, while your organisation is $self->{ORG_NAME}\n"
	  and return;
	$base   = "ou=$service,ou=services,ou=$site,ou=Sites,$self->{LDAPDN}";
	$filter = "(&(objectClass=$class)(name=$name))";
  }
  my $mesg = $ldap->search(base => "$base", filter => "$filter");
  my $total = $mesg->count;
  if (!$total) {
	(!$self->{SILENT})
	  and print STDERR "Warning: no $service $name defined at $site\n";
	return;
  }
  my $entry = $mesg->entry(0);

  #  print "GOT $total\n";
  #  $se->{$service} = $entry->get_value('name');
  foreach my $attr ($entry->attributes) {
	my $value = $entry->get_value($attr);
	my @list  = $entry->get_value($attr);
	$attr = uc($attr);
	$DEBUG
	  and $self->debug(7, "Putting $attr as $value\n\tAnd ${attr}_LIST=@list");
	$se->{"$attr"}        = $value;
	$se->{"${attr}_LIST"} = \@list;
  }

  #here we have to look for all the services that depend on this one
  $DEBUG and $self->debug(2, "Looking for the services that depend on $name");
  $mesg = $ldap->search(
	base   => "name=$name,$base",
	filter => "!(name=$name)"
  );
  if ($mesg->count) {
	$DEBUG and $self->debug(1, "This is in fact a 'virtual' service");
	foreach my $serv ($mesg->entries) {
	  my $name = uc($serv->get_value("name"));
	  $DEBUG and $self->debug(2, "Configuring the subservice $name");
	  $se->{"VIRTUAL_$name"} = {};
	  $se->{"VIRTUAL_$name"}->{FULLNAME} = "$self->{ORG_NAME}::${site}::$name";
	  foreach my $attr ($serv->attributes) {
		my $value = $serv->get_value($attr);
		my @list  = $serv->get_value($attr);
		$attr                                        = uc($attr);
		$se->{"VIRTUAL_$name"}->{uc($attr)}          = $value;
		$se->{"VIRTUAL_$name"}->{uc("${attr}_LIST")} = \@list;
	  }
	}
  }
  $se->{"FULLNAME"} = "$self->{ORG_NAME}::${site}::$se->{NAME}";
  $disconnect and $ldap->unbind;
  return $se;
}

sub GetMaxJobs {
  my $this       = shift;
  my $host       = shift;
  my $ldap       = (shift or "");
  my $disconnect = 0;
  if (!$ldap) {
	$ldap = Net::LDAP->new($self->{LDAPHOST})
	  or print STDERR "Error contacting ldap: $@"
	  and return;
	$ldap->bind or print STDERR "Error binding to LDAP" and return;
	$disconnect = 1;
  }
  $self->debug(1, "Searching for $host in ldap");
  my $filter = "(&(objectClass=AliEnCE)(host=$host))";
  my $base   = "$self->{LDAPDN}";
  my $mesg   = $ldap->search(base => "$base", filter => "$filter");
  my $total  = $mesg->count;
  if (!$total) {
	$self->{LOGGER}->error("Config", "Warning: '$host' can't execute jobs");
	$disconnect and $ldap->unbind;
	return;
  }
  my $entry      = $mesg->entry(0);
  my $jobs       = ($entry->get_value('maxjobs') or "");
  my $queuedJobs = ($entry->get_value('maxqueuedjobs') or "");
  $disconnect and $ldap->unbind;
  $self->debug(1, "Returning $jobs, $queuedJobs");
  return $jobs, $queuedJobs;
}

sub getInfoDomain {
  my $self       = shift;
  my $domain     = shift;
  my $ldap       = (shift or "");
  my $disconnect = 0;
  $self->info("Getting info of $domain");
  if (!$ldap) {
	$ldap = Net::LDAP->new($self->{LDAPHOST})
	  or print STDERR "Error contacting ldap: $@"
	  and return;
	$ldap->bind or print STDERR "Error binding to LDAP" and return;
	$disconnect = 1;
  }
  my $base   = "ou=Sites,$self->{LDAPDN}";
  my $filter = "(&(objectClass=AliEnSite)(domain=$domain))";
  my $mesg   = $ldap->search(base => "$base", filter => "$filter");
  $mesg->code && die $mesg->error;
  my $total = $mesg->count;
  if (!$total) {
	$self->info("ERROR: There are no sites with domain '$domain'");
	$disconnect and $ldap->unbind;
	return;
  }
  $self->info("There are $total sites with domain '$domain'");
  my $entry = $mesg->entry(0);
  my $attr;
  my $object = {};
  foreach $attr ($entry->attributes) {
	my $value = $attr;
	$value =~ s/([A-Z])/_$1/g;
	$value = uc($value);
	$self->info("Putting $value as " . $entry->get_value($attr));
	$object->{$value} = $entry->get_value($attr);
  }
  $disconnect and $ldap->unbind;
  return $object;
}

sub getAttributes {
  my $self   = shift;
  my $entry  = shift;
  my $noList = shift;
  my $target = {};
  foreach my $attr ($entry->attributes) {
	my $value = $attr;
	$value =~ s/([A-Z])/_$1/g;
	$value = uc($value);
	$target->{$value} = $entry->get_value($attr);
	unless ($noList) {
	  my @list = $entry->get_value($attr);
	  $target->{"${value}_LIST"} = \@list;
	}
  }
  return $target;
}

sub GetTopLevelServices {
  my $self = shift;
  my $ldap = shift;
  $self->GetgContainer($ldap)
	or return;
  return 1;
}

sub GetgContainer {
  my $self = shift;
  my $ldap = shift;
  $self->debug(1, "Getting the gContainer Config");
  my $filter = "(&(objectClass=AliEngContainer)(ou=gContainer))";
  my $base   = "ou=Services,$self->{LDAPDN}";
  my $mesg   = $ldap->search(                                       # perform a search
	base   => "$base",
	filter => "$filter"
  );
  if ($mesg->count != 1) {
	$self->debug(1, "Could not find gContainer Configuration");
	return 1;
  }
  $self->{G_CONTAINER} = $self->getAttributes($mesg->entry(0));
  $filter              = "(&(objectClass=AliEngContainerJudge))";
  $base                = "ou=Judges,ou=gContainer,ou=Services,$self->{LDAPDN}";
  $mesg                = $ldap->search(                                           # perform a search
	base   => "$base",
	filter => "$filter"
  );
  my $total = $mesg->count;
  $self->debug(1, "We have $total judges");
  $self->{G_CONTAINER}->{JUDGES_LIST} = [];
  for (my $i = 0 ; $i < $total ; ++$i) {
	push @{$self->{G_CONTAINER}->{JUDGES_LIST}}, $self->getAttributes($mesg->entry($i), 1);
  }
  $filter = "(&(objectClass=AliEngContainerService))";
  $base   = "ou=Services,ou=gContainer,ou=Services,$self->{LDAPDN}";
  $mesg   = $ldap->search(                                                        # perform a search
	base   => "$base",
	filter => "$filter"
  );
  $total = $mesg->count;
  $self->debug(1, "We have $total services");
  $self->{G_CONTAINER}->{SERVICES_HASH} = {};
  for (my $i = 0 ; $i < $total ; ++$i) {
	my $service     = $self->getAttributes($mesg->entry($i), 0);
	my $serviceName = $service->{NAME};
	my $judgeFilter = "(&(objectClass=AliEngContainerJudge))";
	my $judgeBase   = "ou=Judges,name=$serviceName,ou=Services,ou=gContainer,ou=Services,$self->{LDAPDN}";
	my $judgeMesg = $ldap->search(                                                # perform a search
	  base   => "$judgeBase",
	  filter => "$judgeFilter"
	);
	if ($judgeMesg->count) {
	  my $count = $judgeMesg->count;
	  $self->debug(1, "$serviceName has $count own judges");
	  $service->{JUDGES_LIST} = [];
	  for (my $i = 0 ; $i < $count ; ++$i) {
		push @{$service->{JUDGES_LIST}}, $self->getAttributes($judgeMesg->entry($i), 1);
	  }
	}
	if (grep(/AliEngContainerServiceGAS/, @{$service->{OBJECT_CLASS_LIST}})) {
	  $self->debug(1, "Getting the GAS Modules");
	  my $modulesFilter = "(&(objectClass=AliEnGASMODULE))";
	  my $modulesBase   = "name=$serviceName,ou=Services,ou=gContainer,ou=Services,$self->{LDAPDN}";
	  my $modulesMesg   = $ldap->search(                                                              # perform a search
		base   => "$modulesBase",
		filter => "$modulesFilter"
	  );
	  my $modulesCount = $modulesMesg->count;
	  $self->debug(1, "We have $modulesCount GAS modules");
	  $service->{GAS_MODULES_HASH} = {};
	  for (my $i = 0 ; $i < $modulesCount ; ++$i) {
		my $entry = $modulesMesg->entry($i);
		$service->{GAS_MODULES_HASH}->{$entry->get_value("alias")} = $self->getAttributes($entry, 1);
	  }
	}
	$self->{G_CONTAINER}->{SERVICES_HASH}->{$serviceName} = $service;
  }
  return 1;
}

sub ConfigureApiClient {
  my $apiserver   = $self->{"API_SERVER_LIST"};
  my $gclientlist = "";
  if (scalar @$apiserver > 0) {
	foreach (@$apiserver) {
	  $gclientlist .= "$_|";
	}
  }
  $ENV{GCLIENT_SERVER_LIST} = "$gclientlist";
}
return 1;
