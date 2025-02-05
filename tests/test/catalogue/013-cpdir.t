use strict;

use AliEn::UI::Catalogue::LCM;

my $c=AliEn::UI::Catalogue::LCM->new({user=>"newuser"}) or exit(-2);

$c->execute("rmdir", "-rf", "cpDir/");

$c->execute("mkdir", "-p", "cpDir/source/subdir1") or exit(-2);

for (my $i=10; $i;$i--) {
  print "Adding file cpDir/source/file$i\n";
  $c->execute("add", "-silent", "cpDir/source/file$i", "$ENV{ALIEN_HOME}/Environment") or exit(-2);
}
 $c->execute("add", "-silent","cpDir/source/subdir1/Anotherfile", "$ENV{ALIEN_HOME}/Environment") or exit(-2);

#

$c->execute("cp", "cpDir/source", "cpDir/target") or exit(-2);
print "Let's check that the files exist...\n";


compareDirectory($c,"cpDir/target", "file1","file2", "file3", "file4", "file5", "file6","file7", "file8","file9", "file10", 'subdir1') or exit(-2);
compareDirectory($c,"cpDir/target/subdir1", "Anotherfile") or exit(-2);

compareDirectory($c, "cpDir", "source", "target") or exit(-2);
print "\n\n\n\nCopying to a non existent directory works!!\n";

#$c->execute("debug",5);
$c->execute("cp", "cpDir/source", "cpDir/target") or exit(-2);
#$c->execute("debug",0);
compareDirectory($c,"cpDir/target/", "source","file1","file2", "file3", "file4", "file5", "file6","file7", "file8","file9", "file10", "subdir1") or exit(-2);

compareDirectory($c,"cpDir/target/source", "file1","file2", "file3", "file4", "file5", "file6","file7", "file8","file9", "file10", "subdir1") or exit(-2);
compareDirectory($c,"cpDir/target/source/subdir1", "Anotherfile") or exit(-2);

print "ho gaya----ok\n";



sub compareDirectory{
  my $c=shift;
  my $dir=shift;
  my @entries=@_;
  print "Checking directory $dir (needs @entries)...\n";
  my @files=$c->execute("ls", "$dir") or return;

  foreach my $file (@files){
    grep (/^$file$/, @entries) or print "FILE $file is not expected (@entries)\n" and return;
    @entries=grep (! /^$file$/, @entries);
  }
  
  if ($#entries>-1) {
    print "THERE ARE SOME FILES MISSING\n (@entries)\n"; 
    exit(-2);
  }
  print "ok\n";
}
