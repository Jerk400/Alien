use strict;
use Test;
use Net::Domain;
use gapi;

BEGIN { plan tests => 1;}

{
    $ENV{"X509_CERT_DIR"}="$ENV{'GLOBUS_LOCATION'}/share/certificates";	
    $ENV{"GCLIENT_NOPROMPT"}="1";

    print "Connecting to API service ...";
    my $host=Net::Domain::hostname();
    my $gapi = new gapi({host=>"$host",port=>"10000",user=>"$ENV{'USER'}"});
    if (!defined $gapi) {
	exit(-2)
    } else  {
	print "ok\n";
	my $motdfile = "$ENV{'HOME'}/.alien/apiservice.motd";
	print "Writing MOTD $motdfile ...";
	unlink "$motdfile";
	my $motd = "Welcome to the API Service at $host port 10000!\n";
	open FILE ,">$motdfile";
	print FILE "$motd";
	close FILE;
	if (! -e "$ENV{'HOME'}/.alien/apiservice.motd" ) {
	    exit(-2);
	}
	print "ok\n";
	print "Comparing MOTD ...";
	my $result = $gapi->execute("motd ");
	if ($result->{stdout} ne $motd) {
	    exit(-2);
	}
	print "ok\n";
    }

  ok(1);
}

