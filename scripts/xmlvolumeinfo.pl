# perl script to calculate basically the volume of structures
#############################################################################################################################

### >>>
use strict;
use Getopt::Long;
use File::Copy;
use File::Path;
use File::Basename;
use Term::ANSIColor;
use Spreadsheet::WriteExcel;

### local local modules
die "FATAL ERROR: Missing global path variable HITHOME linked to HICoreTools." unless ( defined($ENV{HITHOME}) );
use lib $ENV{HITHOME}."/src/perl";
use hitperl;
use hitperl::atlas;
use hitperl::database;
use hitperl::ontology;
use hitperl::image;
use hitperl::repos;

### core settings
my $ATLASPATH = $ENV{ATLASPATH};
$ATLASPATH =~ s/\\/\//g;
printfatalerror "FATAL ERROR: Invalid atlas path '".$ATLASPATH."': $!" unless ( -d $ATLASPATH );
my $DATABASEPATH = $ENV{DATABASEPATH};
printfatalerror "FATAL ERROR: Invalid database path '".$DATABASEPATH."': $!" unless ( -d $DATABASEPATH );
my $timestamp = sprintf "%06x",int(rand(100000));

### global data
my %revisions = ();

### >>>
sub getXMLAttribute {
 my ($line,$keyword) = @_;
 my @elements1 = split(/${keyword}/,$line);
 my @elements2 = split(/\"/,$elements1[1]);
 return $elements2[1];
}

sub getBrains {
 my $path = shift;
 my @pmbrains = ();
 my @dirs = getDirent($path);
 foreach my $dir (@dirs) {
  next unless ( $dir =~ m/^pm/i );
  push(@pmbrains,$dir);
 }
 return @pmbrains;
}

sub getStructures {
 my ($filename,$verbose) = @_;
 my @structures = ();
 print "Loading structure file '".$filename."'...\n" if ( $verbose );
 open(FPin,"<$filename") || printfatalerror "FATAL ERROR: Could not open structure file '".$filename."' for reading: $!";
  while ( <FPin> ) {
   if ( $_ =~ m/^structures/i ) {
    chomp($_);
    $_ =~ s/structures//i;
    $_ =~ s/\=//i;
    $_ =~ s/^\s+//g;
    $_ =~ s/\s+$//g;
    $_ =~ s/_L/_l/g;
    $_ =~ s/_R/_r/g;
    @structures = split(/\ /,$_);
    last;
   }
  }
 close(FPin);
 print " got ".@structures." structures: (@structures).\n" if ( $verbose );
 return @structures;
}

# get critical points info of all modalities!
sub getCriticalIntersectionsFromFile {
 my ($datatype,$project,$brain,$structure,$contourReconPath,$pedantic) = @_;
 # print "type[$datatype], project[$project], brain[$brain], structure[$structure]\n";
 my @types = ("orig","lin","nlin");
 my %values = ();
 my $inpath = "";
 foreach my $type (@types) {
  $inpath = $contourReconPath."/".$project."/XML/".$type."/".$brain."/astructures";
  if ( $datatype eq "self" ) {
   $inpath .= "/".$structure."/intersection";
  } else {
   $inpath .= "/all/intersection";
  }
  if ( ! -d $inpath ) {
   warn "WARNING: Invalid inpath '".$inpath."'.\n";
   $values{$type} = -1;
   exit(1) if ( $pedantic );
   next;
  }
  my $nintersections = 0;
  my @files = getDirent($inpath);
  foreach my $file (@files) {
   next unless ( $file =~ m/_critical$/i );
   my $criticalfile = $inpath."/".$file;
   open(FPcrtin,"<$criticalfile") || printfatalerror "FATAL ERROR: Cannot open '".$criticalfile."' for reading: $!";
    $nintersections += <FPcrtin>;
   close(FPcrtin);
  }
  $values{$type} = $nintersections;
 }
 my @ivalues = ();
 push(@ivalues,$values{"orig"});
 push(@ivalues,$values{"lin"});
 push(@ivalues,$values{"nlin"});
 return @ivalues;
}

sub getCavalieriVolumeFromFile {
 my ($dtype,$project,$brain,$structure,$contourReconPath,$pedantic) = @_;
 my $filename = $contourReconPath."/".$project."/docs/volumes/";
 $filename .= "cavalieri_".$structure."_".$dtype.".txt";
 if ( ! -e $filename ) {
  # printwarning "WARNING: Could not find volume file '".$filename."': project=$project, brain=$brain, structure=$structure, type=$dtype.\n";
  exit(1) if ( $pedantic );
  return 0.0;
 }
 my $volume = 0.0;
 open(FPvolin,"<$filename") || printfatalerror "FATAL ERROR: Could not open '".$filename."' for reading.\n";
  while ( <FPvolin> ) {
   my @values = split(/\ /,$_);
   if ( $values[0] eq "$brain" ) {
    $volume = $values[1];
    last;
   }
  }
 close(FPvolin);
 return $volume;
}

## *** already outsourced *** see 'hitperl::getStructureIdentFromFileName()'
sub getSectionNumber {
 my $lFileName = shift;
 my $lCheckName = $lFileName;
 $lCheckName =~ s/[a-z]+/X/gi;
 my @elements = split(/X/,$lCheckName);
 foreach (@elements) {
  return $_ if ( /^\d+$/ )
 }
 $lFileName =~ tr/0-9/./c;
 $lFileName =~ s/\.//g;
 return($lFileName);
}

## >>>
sub getRevision {
 my ($project,$brain,$section,$contourReconPath,$debug) = @_;
 print "getRevision(): project[$project], brain[$brain], section[$section]\n" if ( $debug );
 if ( keys %revisions == 0 ) {
  my $datapath = $contourReconPath."/".$project;
  print " + datapath='$datapath'\n" if ( $debug );
  if ( ! -e $datapath."/.svn" ) {
   print "WARNING: Cannot find '".$datapath."/.svn'.\n";
   return "?";
  }
  my $logfilename = "./tmp/tmp".$timestamp."_svnstatus_".$project.".xml";
  ssystem("svn status --show-updates --xml -v $datapath > $logfilename",$debug);
  printfatalerror "FATAL ERROR: Cannot find '".$logfilename."'." unless ( -e $logfilename );
  print " + logfilename='".$logfilename."'\n" if ( $debug );
  open(FPlogfile,"<$logfilename") || printfatalerror "FATAL ERROR: Cannot open '".$logfilename."' for reading: $!";
   my $haveValidEntry = 0;
   my $dataident = "";
   while ( <FPlogfile> ) {
    chomp($_);
    if ( $_ =~ m/<entry/i ) {
     my $pathline = $_;
     while ( !($pathline =~ m/\>$/) ) {
       $pathline = <FPlogfile>;
       last if ( $pathline =~ m/path=/ );
     }
     my $pathname = getXMLAttribute($pathline,"path");
     $haveValidEntry = 0;
     next unless ( $pathname =~ m/\.xml$/i );
     $haveValidEntry = 1;
     my @elements = split(/\//,$pathname);
     my $brainname = $elements[-2];
     my $xmlfilename = $elements[-1];
     my $sectionnumber = getSectionNumber($xmlfilename);
     $dataident = $brainname.".".$sectionnumber;
     print " + pathname[".$pathname."].\n" if ( $debug );
    } elsif ( $haveValidEntry && $_ =~ m/<commit/i ) {
     my $commitline = $_;
     while ( !($commitline =~ m/\>$/) ) {
       $commitline = <FPlogfile>;
       last if ( $commitline =~ m/revision=/ );
     }
     my $revision = getXMLAttribute($commitline,"revision");
     print " + $dataident=$revision\n" if ( $debug );
     $revisions{$dataident} = $revision;
    }
   }
  close(FPlogfile);
  unlink($logfilename);
  print " + $datapath -> $logfilename\n" if ( $debug );
 }
 my $dataident = $brain.".".$section;
 return $revisions{$dataident} if ( exists($revisions{$dataident}) );
 return -1;
}

### getting input parameters
my $ARGC = $#ARGV+1;
my $help = 0;
my $echo = 0;
my $log = 0;
my $float = 0;
my $update = 0;
my $overwrite = 0;
my $verbose = 0;
my $silent = 0;
my $history = 0;
my $pedantic = 0;
my $basic = 0;
my $nosvn = 0;
my $mystrucsonly = 0;
my $isbigbrain = 0;
my $lDoTest = 0;
my $lDoDebug = 0;
my $lDoPixels = 0;
my $lDoSimpson = 0;
my $lDoStatistics = 0;
my $lSkipSummary = 0;
my $lSkipFormular = 0;
my $lShowSurface = 0;
my $lShowTopology = 0;
my $lShowDistance = 0;
my $lCompleteAtlas = 0;
my $lShowVolumeAlteration = 0;
my $lLoadDistance = 0;
my $lIsNested = 0;
my $lIsClosed = 0;
my $lAreaString = "";
my $lDataType = "orig";      ## orig|lin|nlin
my $lProjectString = "";
my $lResolution = 1200;      ## in pixelperinch
my $lDistance = 0.02;        ## distance between adjacent sections in mm
my $surfGenMethod = "crude"; ## crude|hittriangulate|delaunay|cgal
my $isdefaultsystem = 0;
my $isworkinprogress = 0;
my $species = "human";
my $projectpath = undef;
my $onlybrain = undef;
my $onlysection = undef;
my $reposlevel = undef;
my $hostname = "localhost";
my $accessfile = "login.dat";
my $ontologyfile = undef;
my @argvlist = ();
my @procareas = ();
my %factors = ();
my %genders = ();
my %ages = ();
my %weights = {};
my %brains = ();
my %brainidents = ();
my %strucs = ();
my $i = 0;

### >>>
sub printusage {
 my $errortext = shift;
 if ( defined($errortext) ) {
  print color('red');
  print "error:\n ".$errortext.".\n";
  print color('reset');
 }
 print "usage:\n ".basename($0)." [(-h|--help)][(-t|--test)][(-d|--debug)][--datatype <name=$lDataType>][--pixels][--pedantic][--stats][--echo][--complete-atlas]\n";
 print "\t[(-o|--overwrite)][--resolution <value=$lResolution>][--distance <value[mm]=$lDistance>][--surface][--topology][--showdistance][--workinprogress]\n";
 print "\t[--float][--mystrucsonly][--surfgen <name=$surfGenMethod>][--noformular][--areas <comma separated list>][--nosummary][--nested][--default-system]\n";
 print "\t[--loaddistance][(-v|--verbose)][--species <name=$species>][--atlaspath <name>][--silent][--log][--basic][--nosvn][--bigbrain]\n";
 print "\t[--repos <number>][--ontology <filename>][--onlybrain <name>][--onlysection <name>][--projectpath <name>] --project <project>\n";
 print "parameter:\n";
 print " version.................... ".getScriptRepositoryVersion($0,$lDoDebug)."\n";
 print " script path................ ".dirname(__FILE__)."\n";
 print " atlas path................. ".$ATLASPATH."\n";
 print " project path............... <projectpath=atlaspath>/projects/contourrecon/data\n";
 print " database path.............. ".$DATABASEPATH."\n";
 print " date string................ ".getDateString()."\n";
 print " last call.................. '".getLastProgramLogMessage($0)."'\n";
 exit(1);
}
if ( @ARGV>0 ) {
 foreach my $argnum (0..$#ARGV) {
  push(@argvlist,$ARGV[$argnum]);
 }
 GetOptions(
  'help|?' => \$help,
  'verbose|v+' => \$verbose,
  'test|t+' => \$lDoTest,
  'update|u+' => \$update,
  'log+' => \$log,
  'history+' => \$history,
  'float+' => \$float,
  'nosvn+' => \$nosvn,
  'debug|d+' => \$lDoDebug,
  'basic|b+' => \$basic,
  'bigbrain+' => \$isbigbrain,
  'workinprogress+' => \$isworkinprogress,
  'overwrite|o+' => \$overwrite,
  'pedantic+' => \$pedantic,
  'mystrucsonly+' => \$mystrucsonly,
  'complete-atlas+' => \$lCompleteAtlas,
  'default-system+' => \$isdefaultsystem,
  'simpson+' => \$lDoSimpson,
  'pixels+' => \$lDoPixels,
  'noformular+' => \$lSkipFormular,
  'nosummary+' => \$lSkipSummary,
  'closed+' => \$lIsClosed,
  'nested+' => \$lIsNested,
  'surface+' => \$lShowSurface,
  'topology+' => \$lShowTopology,
  'loaddistance+' => \$lLoadDistance,
  'stats+' => \$lDoStatistics,
  'echo|e+' => \$echo,
  'silent+' => \$silent,
  'species=s' => \$species,
  'datatype=s' => \$lDataType,
  'resolution=s' => \$lResolution,
  'distance=s' => \$lDistance,
  'areas=s' => \$lAreaString,
  'hostname=s' => \$hostname,
  'access=s' => \$accessfile,
  'repos=i' => \$reposlevel,
  'ontology=s' => \$ontologyfile,
  'onlybrain=s' => \$onlybrain,
  'onlysection=i' => \$onlysection,
  'projectpath=s' => \$projectpath,
  'atlaspath=s' => \$ATLASPATH,
  'project|p=s' => \$lProjectString) ||
 printusage();
}
printProgramLog($0,1) if $history;
printusage() if $help;
printusage("Missing input parameter(s)") unless ( $lProjectString );

### >>>
createProgramLog($0,\@argvlist);

### >>>
@procareas = split(/\,/,$lAreaString) if ( $lAreaString );
if ( $lDoStatistics ) {
 $lShowSurface = 1;
 $lShowTopology = 1;
 $lShowDistance = 1;
}
if ( $isdefaultsystem ) {
 $verbose = 1;
 $projectpath = getAtlasContourDataDrive()."/Projects/Atlas";
}

### check input parameters
printfatalerror "FATAL ERROR: Cannot setup bigbrain and workinprogress option at the same time." if ( $isbigbrain && $isworkinprogress );

## connect to database
my $accessfilename = $DATABASEPATH."/scripts/data/".$accessfile;
my @accessdata = getAtlasDatabaseAccessData($accessfilename);
printfatalerror "FATAL ERROR: Malfunction in 'getAtlasDatabaseAccessData(".$accessfilename.")'." if ( @accessdata!=2 );
my $dbh = connectToAtlasDatabase($hostname,$accessdata[0],$accessdata[1]);

### setup core data input paths
my $lContourReconPath = defined($projectpath)?$projectpath:$ATLASPATH;
$lContourReconPath .= "/projects/contourrecon/data";
$lContourReconPath .= "/bigbrain" if ( $isbigbrain );
$lContourReconPath .= "/workinprogress" if ( $isworkinprogress );
printfatalerror "FATAL ERROR: Invalid contour recon path '".$lContourReconPath."': $!" unless ( -d $lContourReconPath );
my $lAtlasBrainDataPath = $ATLASPATH."/data/brains";
printwarning "WARNING MESSAGE: Invalid atas data brains path '".$lAtlasBrainDataPath."': $!" unless ( -d $lAtlasBrainDataPath );

### loading volume correction file
my $lCorrectFile = dirname(__FILE__)."/data/volcorrection.txt";
open(INFILE,"<$lCorrectFile") || printfatalerror "FATAL ERROR: Cannot open '".$lCorrectFile."' for reading: $!";
while ( <INFILE> ) {
 next if ( $_ =~ m/^#/ );
 my @line = split(/\ /,$_);
 my $nvalues = scalar(@line);
 $factors{$line[0]} = $line[1];
 $genders{$line[0]} = $line[2];
 $ages{$line[0]} = $line[3];
 $brainidents{$line[0]} = $line[4];
 $weights{$line[0]} = 0;
 $weights{$line[0]} = $line[6] if ( $nvalues>=7 );
}
close(INFILE);

### >>>
if ( $lCompleteAtlas ) {
 print "Computing excel file for the complete atlas...\n" if ( $verbose );
 my @sides = ("l","r");
 my %ontologydata = ();
 my %structureinfos = {};
 my %combistructures = ();
 my %iscombistructure = ();
 my %prjcombistructures = ();
 if ( defined($ontologyfile) ) {
  print " loading ontology file '".$ontologyfile."'...\n" if ( $verbose );
  %ontologydata = getNamedFieldsFromOntologyFile($ontologyfile,$verbose,$lDoDebug);
  while ( my ($key,$value) = each(%ontologydata) ) {
   my %fielddatas = %{$value};
   my $status = $fielddatas{"Status"};
   my $lobe = $fielddatas{"Lobes"};
   my $prjname = $fielddatas{"Project name internal"};
   my $psname = $prjname.".".$fielddatas{"Structure name intern"};
   my $summaryname = $fielddatas{"Structure summary names"};
   my $labelname = $fielddatas{"HBP display labels"};
   print "lobe=".$lobe." <-> ".$psname." <-> ".$labelname." <-> ".$summaryname."\n" if ( $psname =~ m/^retrosplenialercortex/ );
   $structureinfos{$psname} = $lobe."---".$labelname."---".$status."---".$summaryname;
   if ( !($summaryname =~ m/^unknown$/) ) {
    @{$combistructures{$summaryname}} = () unless ( exists($combistructures{$summaryname}) );
    push(@{$combistructures{$summaryname}},$psname);
    @{$prjcombistructures{$prjname}} = () unless ( exists($prjcombistructures{$prjname}) );
    push(@{$prjcombistructures{$prjname}},$psname);
    $iscombistructure{$psname} = $summaryname;
   }
  }
 }
 my @usedatlasbrains = ();
 my @skippedprojects = ();
 my %atlasprojects = ();
 my %atlasprojectbrains = ();
 my %allatlasprojects = getAtlasStatusProjects($lProjectString,$verbose);
 print "Found ".scalar(keys(%allatlasprojects))." atlas projects: (".join("\,",keys(%allatlasprojects)).").\n";
 foreach my $atlasproject ( keys %allatlasprojects) {
  my $status = $allatlasprojects{$atlasproject};
  if ( $status =~ m/public/i || $status =~ m/internal/i ) {
   print " + scanning atlas project '".$atlasproject.", status=".$allatlasprojects{$atlasproject}."...\n" if ( $verbose );
   my $strucfilename = $lContourReconPath."/".$atlasproject."/structures.inc";
   my @projectareas = getStructures($strucfilename,0);
   if ( scalar(@projectareas)>0 ) {
    my @projectbrains = getBrains($lContourReconPath."/".$atlasproject."/XML/orig",0);
    push(@usedatlasbrains,@projectbrains);
    print "  + found ".scalar(@projectareas)." structures=(".join(",",@projectareas).") in brains=(".join(",",@projectbrains).")\n";
    @{$atlasprojects{$atlasproject}} = @projectareas;
    @{$atlasprojectbrains{$atlasproject}} = @projectbrains;
   }
  } else {
   push(@skippedprojects,$atlasproject);
   printwarning " + skipping project ".$atlasproject.", status=".$status.".\n" if ( $verbose );
  }
 }
 @usedatlasbrains = removeDoubleEntriesFromArray(@usedatlasbrains);
 print " + used ".scalar(@usedatlasbrains)." atlas brains=(".join(",",@usedatlasbrains).")\n" if ( $verbose );
 my $excelFileName = "/tmp/AtlasProject_shrinkage_corrected_volumes_human_";
 $excelFileName .= getDateString();
 $excelFileName .= ".xls";
 my $workbook = Spreadsheet::WriteExcel->new($excelFileName);
  my $format = $workbook->add_format();
  $format->set_bold();
  $format->set_color('black');
  $format->set_align('center');
  my $formattext = $workbook->add_format();
  $formattext->set_color('black');
  $formattext->set_align('center');
  my $formatred = $workbook->add_format();
  $formatred->set_bold();
  $formatred->set_color('red');
  $formatred->set_align('center');
  my $formatgreen = $workbook->add_format();
  $formatgreen->set_bold();
  $formatgreen->set_color('green');
  $formatgreen->set_align('center');
  my $fformat = $workbook->add_format();
  $fformat->set_num_format('0.000');
  $fformat->set_align('center');
  my $worksheet = $workbook->add_worksheet("Shrinkage corrected volumes");
  ## set brain names
  my %brainPos = ();
  my $k = 2;
  foreach my $atlasbrain (@usedatlasbrains) {
   $worksheet->write(0,6+$k,$atlasbrain,$format);
   $worksheet->write(1,6+$k,$genders{$atlasbrain},$formattext);
   $worksheet->write(2,6+$k,$ages{$atlasbrain},$formattext);
   $worksheet->write(3,6+$k,$weights{$atlasbrain},$formattext);
   $brainPos{$atlasbrain} = $k;
   $k += 1;
  }
  ## set project/structurenames
  $worksheet->set_column(0,0,25);
  $worksheet->set_column(1,0,12);
  $worksheet->set_column(2,0,16);
  $worksheet->set_column(3,0,3);
  $worksheet->set_column(4,0,3);
  $worksheet->set_column(5,0,3);
  $worksheet->set_column(6,0,5);
  $worksheet->set_column(7,0,32);
  my $xn = 6+1;
  my @missingprojects = ();
  ## start project processing here
  for my $key ( sort {$a<=>$b} keys %atlasprojects ) {
   print " + processing project ".$key."...\n" if ( $verbose );
   my $volfilename = $lContourReconPath."/".$key."/docs/values/volume_cavalieri_orig.info";
   my %volinfos = ();
   if ( -e $volfilename ) {
    print "  + loading cavalieri volume file '".$volfilename."'...\n" if ( $verbose );
    open(FPin,"<$volfilename") || printfatalerror "FATAL ERROR: Cannot open '".$volfilename."' for reading: $!";
     while ( <FPin> ) {
      next unless ( $_ =~ m/^pm/ );
      chomp($_);
      my @values = split(/ /,$_);
      %{$volinfos{$values[0]}} = () unless ( exists($volinfos{$values[0]}) );
      for ( my $i=1 ; $i<scalar(@values) ; $i+=3 ) {
       ${$volinfos{$values[0]}}{$values[$i]} = $values[$i+2];
      }
     }
    close(FPin);
   } else {
    printwarning "WARNING: Cannot find Cavalieri volume info file '".$volfilename."'.\n";
    push(@missingprojects,$key);
   }
   my @projectbrains = @{$atlasprojectbrains{$key}};
   my $prjformat = ($allatlasprojects{$key} =~ m/public/i)?$formatgreen:$formatred;
   $worksheet->write($xn,0,$key,$prjformat);
   $xn += 1;
   ## regular structures
   my @structures = @{$atlasprojects{$key}};
   foreach my $structure (@structures) {
    my $psname = $key.".".$structure;
    $psname =~ s/_l$//i;
    $psname =~ s/_r$//i;
    if ( exists($iscombistructure{$psname}) ) {
     ### nothing
    } else {
     foreach my $projectbrain (@projectbrains) {
      my $yn = $brainPos{$projectbrain};
      my $volume = 0.0;
      $volume = ${$volinfos{$projectbrain}}{$structure} if ( exists($volinfos{$projectbrain}) && exists(${$volinfos{$projectbrain}}{$structure}) );
      ## my $volume = getCavalieriVolumeFromFile("orig",$key,$projectbrain,$structure,$lContourReconPath,$pedantic);
      $worksheet->write($xn,6+$yn,$volume,$fformat); #### HERE ####
     }
     my $hbpname = "unknown";
     my $lobe = "unknown";
     my $status = "unknown";
     my $sumname = "unknown";
     if ( exists($structureinfos{$psname}) ) {
      my @names = split(/---/,$structureinfos{$psname});
      $hbpname = $names[0];
      $lobe = $names[1];
      $status = $names[2];
      $sumname = $names[3];
     }
     $worksheet->write($xn,1,$structure,$format); ### STRUCTURENAME ####
     $worksheet->write($xn,2,$hbpname,$format);
     my $sv = ($structure =~ m/_l$/i )?"0":"1";
     $worksheet->write($xn,3,$sv,$format);
     my $pv = ($status =~ m/public/i)?1:($status =~ m/internal/i)?2:0;
     $worksheet->write($xn,4,$pv,$format);
     my $iss = ($sumname=~m/unknown/)?0:1;
     $worksheet->write($xn,5,$iss,$format);
     ## get db ident
      my $cstructure = $structure;
      $cstructure =~ s/\_l$//;
      $cstructure =~ s/\_r$//;
      ### print " >>> project=$key, structure=$cstructure\n";
      my $prjDBIdent = fetchFromAtlasDatabase($dbh,"SELECT id FROM atlas.projects WHERE name='$key'");
      my $strucDBIdent = fetchFromAtlasDatabase($dbh,"SELECT id FROM atlas.structures WHERE name='$cstructure' AND projectId='$prjDBIdent'");
      $worksheet->write($xn,6,$strucDBIdent,$format);
     ##
     $worksheet->write($xn,7,$lobe,$format);
     $xn += 1;
    }
   }
   ## combi structures
   if ( exists($prjcombistructures{$key}) ) {
    my %summarynames = ();
    my @combistructures = @{$prjcombistructures{$key}};
    foreach my $combistructure (@combistructures) {
     my $psname = $combistructure;
     my $origname = (split(/\./,$combistructure))[1];
     print " found combistructure=$combistructure||$origname -> summaryname=".$iscombistructure{$psname}."\n";
     ## $summarynames{$iscombistructure{$psname}} = $psname;
     push(@{$summarynames{$iscombistructure{$psname}}},$origname);
    }
    foreach my $side (@sides ) {
     foreach my $summaryname ( keys(%summarynames) ) {
      my @cstructures = @{$summarynames{$summaryname}};
      print " combis[$side][$summaryname]=@cstructures\n";
      my $psname = $key.".".(@{$summarynames{$summaryname}})[0];
      my $structure = (split(/\./,$psname))[1];
      ### brain data
       foreach my $projectbrain (@projectbrains) {
        my $yn = $brainPos{$projectbrain};
        my $volume = 0.0;
        foreach my $cstructure (@cstructures) {
         my $ccstructure = $cstructure."_".$side;
         $volume += ${$volinfos{$projectbrain}}{$ccstructure} if ( exists($volinfos{$projectbrain}) && exists(${$volinfos{$projectbrain}}{$ccstructure}) );
        }
        $worksheet->write($xn,6+$yn,$volume,$fformat); #### HERE ####
       }
      ### info
       my $hbpname = "unknown";
       my $lobe = "unknown";
       my $status = "unknown";
       my $sumname = "unknown";
       if ( exists($structureinfos{$psname}) ) {
        my @names = split(/---/,$structureinfos{$psname});
        $hbpname = $names[0];
        $lobe = $names[1];
        $status = $names[2];
        $sumname = $names[3];
       }
       $worksheet->write($xn,1,$summaryname."_".$side,$format); ### STRUCTURENAME ####
       $worksheet->write($xn,2,$hbpname,$format);
       my $sv = ($side =~ m/^l$/i )?"0":"1";
       $worksheet->write($xn,3,$sv,$format);
       my $pv = ($status =~ m/public/i)?1:($status =~ m/internal/i)?2:0;
       $worksheet->write($xn,4,$pv,$format);
       my $iss = ($sumname=~m/unknown/)?0:1;
       $worksheet->write($xn,5,$iss,$format);
       ## get db ident
       my $cstructure = $structure;
       $cstructure =~ s/\_l$//;
       $cstructure =~ s/\_r$//;
       ### print " >>> project=$key, structure=$cstructure\n";
       my $prjDBIdent = fetchFromAtlasDatabase($dbh,"SELECT id FROM atlas.projects WHERE name='$key'");
       my $strucDBIdent = fetchFromAtlasDatabase($dbh,"SELECT id FROM atlas.structures WHERE name='$summaryname' AND projectId='$prjDBIdent'");
       print "sum=$summaryname|$cstructure>>$strucDBIdent\n";
       $worksheet->write($xn,6,$strucDBIdent,$format);
       ##
       $worksheet->write($xn,7,$lobe,$format);
      ###
      $xn += 1;
     }
    }
    ## exit(1);
   }
  }
  ## >>>
 $workbook->close();
 printwarning "WARNING: Skipped ".scalar(@skippedprojects)." atlas projects: (".join("\,",@skippedprojects).").\n";
 printwarning "WARNING: Missed Cavalieri volume values for ".scalar(@missingprojects)." projects (".join("\,",@missingprojects).")!\n";
 print "Saved Excel file '".$excelFileName."'.\n" if ( $verbose );
 $dbh->disconnect();
 exit(1);
}

### check whether we have a valid directory, a text file containing all dirs or something stupid
my @lProjectList = ();
if ( -e $lProjectString ) {
 open(INFILE,"<$lProjectString") || printfatalerror "FATAL ERROR: Cannot open '".$lProjectString."': $!";
 while ( <INFILE> ) {
  push(@lProjectList,$_);
 }
 close(INFILE);
} else {
 my $lDataPath = $lContourReconPath."/".$lProjectString;
 if ( -d $lDataPath ) {
  push(@lProjectList,$lProjectString);
 } else {
  printfatalerror "FATAL ERROR: Invalid name for project.";
  exit(1);
 }
}

### here we setup everything for the directory
my $lProjectName = $lProjectList[0];
my $lProjectPath = $lContourReconPath."/".$lProjectName;
$lProjectPath .= "/.repos/".$reposlevel if ( defined($reposlevel) );
printfatalerror "FATAL ERROR: Invalid project path '".$lProjectPath."': $!" unless ( -d $lProjectPath );
if ( $mystrucsonly ) {
 my $strucfilename = $lProjectPath."/structures.inc";
 @procareas = getStructures($strucfilename,$verbose);
}
my $lProjectDataPath = $lProjectPath."/XML/".$lDataType;
printfatalerror "FATAL ERROR: Invalid project data path '".$lProjectDataPath."': $!" unless ( -d $lProjectDataPath );
print "DEBUG: ProjectDataPath[".$lProjectDataPath."]\n" if ( $lDoDebug );

### >>>
sub getAssembleVolumeChange {
 my ($lProject,$lBrain,$lStructure) = @_;
 my $assemblepath = $lContourReconPath."/".$lProject."/assemble";
 $assemblepath .= "F" if ( $float );
 $assemblepath .= "/nlin/".$lBrain;
 my $origfile = $assemblepath."/".$lStructure."_".$lBrain."histo_nlin_small_pad.vff.gz";
 my $gaussfile = $assemblepath."/".$lStructure."_".$lBrain."histo_nlin_small_pad_gaussF.vff.gz";
 if ( ! -e $origfile || ! -e $gaussfile ) {
  printwarning "WARNING: Cannot find file '".$origfile."' and/or gauss file '".$gaussfile."'.\n";
  return 0.0;
 }
 print "project=$lProject, brain=$lBrain, structure=$lStructure\n" if ( $verbose );
 my $origvolume = getHistogramVolume($origfile,1);
 my $gaussvolume = getHistogramVolume($gaussfile,1);
 print " origfile  = $origfile   => V = $origvolume\n";
 print " gaussfile = $gaussfile  => V = $gaussvolume\n";
 return $gaussvolume/$origvolume;
}

### >>>
sub getNLinContourTopologyValues {
 my ($lProject,$lBrain,$lStructure) = @_;
 my @topoValues = ("?","?");
 my $topoFile = $lContourReconPath."/".$lProject."/XML/nlin/".$lBrain."/astructures/".$lStructure."/graphs";
 $topoFile .= "/".$lBrain."_".$lStructure."_nlin.info";
 return @topoValues unless ( -e $topoFile );
 open(FPin,"<$topoFile") || printfatalerror "FATAL ERROR: Cannot open '".$topoFile."' for reading: $!";
  while ( <FPin> ) {
   chomp($_);
   if ( $_ =~ m/numComponents/ ) {
    $topoValues[0] = getXMLAttribute($_,"numComponents");
   } elsif ( $_ =~ m/<component/ ) {
    $topoValues[1] = getXMLAttribute($_,"euler");
   }
  }
 close(FPin);
 return @topoValues;
}

### >>>
sub getTraceLength {
 my @xcoords = @{$_[0]};
 my @ycoords = @{$_[1]};
 my $dim = @xcoords;
 my $lLength = 0.0;
 for ( my $i=1 ; $i<$dim ; $i++ ) {
  my $dx = $xcoords[$i]-$xcoords[$i-1];
  my $dy = $ycoords[$i]-$ycoords[$i-1];
  $lLength += sqrt($dx*$dx+$dy*$dy);
 }
 return($lLength);
}

sub getArea {
 my @xcoords = @{$_[0]};
 my @ycoords = @{$_[1]};
 my $dim = scalar(@xcoords);
 my $lArea = 0.0;
 if ( $lIsClosed==0 ) {
  push(@xcoords,$xcoords[0]);
  push(@ycoords,$ycoords[0]);
 }
 for ( my $i=0 ; $i<$dim ; $i++ ) {
  $lArea += $xcoords[$i]*$ycoords[$i+1]-$xcoords[$i+1]*$ycoords[$i];
 }
 if ( $lDoPixels==0 ) {
  $lArea = $lArea/($lResolution*$lResolution)*25.4*25.4;
 }
 return(abs(0.5*$lArea));
}

### >>>
sub getArea2 {
 my $datastring = shift;
 my @xyvalues = split(/\ /,$datastring);
 my @xcoords = ();
 my @ycoords = ();
 foreach my $xyvalue (@xyvalues) {
  my @coords = split(/\,/,$xyvalue);
  if ( scalar(@coords)==2 ) {
   push(@xcoords,$coords[0]);
   push(@ycoords,$coords[1]);
  }
 }
 return getArea(\@xcoords,\@ycoords);
}

### >>>
sub getArea3 {
 my $datastring = shift;
 my @xyvalues = split(/\,/,$datastring);
 my @xcoords = ();
 my @ycoords = ();
 for ( my $n=0 ; $n<scalar(@xyvalues) ; $n+=2 ) {
  push(@xcoords,$xyvalues[$n]);
  push(@ycoords,$xyvalues[$n+1]);
 }
 return getArea(\@xcoords,\@ycoords);
}

sub getcentroid {
 my @xcoords = @{$_[0]};
 my @ycoords = @{$_[1]};
 my @centroid = ();
 my $lArea = getArea(\@xcoords,\@ycoords);
 if ( $lArea==0.0 ) {
  print "FATAL ERROR: Invalid area.\n";
  exit(1) if ( $pedantic );
  return(@centroid);
 }
 my $dim = @xcoords;
 my $xc = 0.0;
 my $yc = 0.0;
 for ( my $i=0 ; $i<$dim ; $i++ ) {
  my $fak = ($xcoords[$i]*$ycoords[$i+1]-$xcoords[$i+1]*$ycoords[$i]);
  $xc += ($xcoords[$i]+$xcoords[$i+1])*$fak;
  $yc += ($ycoords[$i]+$ycoords[$i+1])*$fak;
 }
 push(@centroid,$xc/(6.0*$lArea));
 push(@centroid,$yc/(6.0*$lArea));
 return(@centroid);
}

sub loadSectionDistance {
  my ($brain,$species,$distance) = @_;
  my $lBrainSpecFile = $lAtlasBrainDataPath."/".$species."/postmortem/".$brain."/histo/".$brain."_info.inc";
  if ( ! -e $lBrainSpecFile ) {
   unless ( $silent ) {
    warn "WARNING: Could not find spec file '".$lBrainSpecFile."'. using default distance '$distance'.\n";
   }
   return $distance;
  }
  open(FP,"<$lBrainSpecFile") || printfatalerror "FATAL ERROR: Could not open '".$lBrainSpecFile."': $!";
  while ( <FP> ) {
   if ( $_ =~ m/^distance=/i ) {
    chomp($_);
    my $myDistance = $_;
    $myDistance =~ s/distance=//i;
    close(FP);
    return $myDistance;
   }
  }
  close(FP);
  unless ( $silent ) {
   warn "WARNING: Could not find distance value in '".$lBrainSpecFile."'. Using default distance '".$distance."'.\n";
  }
  return $distance;
}

sub getElementFromSurfaceInfoFile {
 my ($filename,$element,$method) = @_;
 open(INFILE,"<$filename") || printfatalerror "FATAL ERROR: Cannot open '".$filename."': $!";
  while ( <INFILE> ) {
   if ( $_ =~ m/$element/i && $_ =~ m/$method/i ) {
    my @elements = split(/ /,$_);
    return $elements[2];
   }
  }
 close(INFILE);
 printfatalerror "FATAL ERROR: Element '$element' and/or method '$method' not found in '".$filename."'.";
 return 0;
}

# >>>
sub isCriticalContour {
 my ($projectpath,$sectionnr,$areaname) = @_;
 my $inpath = $projectpath."/astructures/".$areaname."/intersection";
 return 0 unless ( -d $inpath );
 my @infiles = getDirent($inpath);
 foreach my $infile (@infiles) {
  next unless ( $infile =~ m/_critical$/i );
  return 1 if ( $infile =~ m/pm$sectionnr/ );
 }
 return 0;
}

######################## start of main part #########################################

### init
my @lStrucs = ();
my @lBrains = ();
### creating excel output
my $lExcelFileName = "/tmp/".$lProjectName."_volume_".$lDataType."_".$species."_";
$lExcelFileName .= getDateString();
$lExcelFileName .= ".xls";
my $workbook = Spreadsheet::WriteExcel->new($lExcelFileName);
my $format = $workbook->add_format();
$format->set_bold();
$format->set_color('black');
$format->set_align('center');
my $format1 = $workbook->add_format();
$format1->set_num_format('0.000');
$format1->set_align('center');
my $format1red = $workbook->add_format();
$format1red->set_num_format('0.000');
$format1red->set_align('center');
$format1red->set_color('red');
my $format1b = $workbook->add_format();
$format1b->set_num_format('0');
$format1b->set_align('center');
my $format2 = $workbook->add_format();
$format2->set_align('right');
my $format3 = $workbook->add_format();
$format3->set_num_format('0.000');
$format3->set_align('center');
$format3->set_bg_color(43);  ## 26
$format3->set_pattern(1);
my $format4 = $workbook->add_format();
$format4->set_bold();
$format4->set_align('center');
$format4->set_color('red');
my $speccode = "pm";
$speccode = $species unless ( $species eq "human" );
my $arealogfile = createOutputPath($lProjectPath."/docs");
$arealogfile .= "/".$lProjectName."_traceareas_".getDateString().".log";
print "creating area log file '".$arealogfile."'.\n" if ( $verbose );
open(FPAreaLogout,">$arealogfile") || printfatalerror "FATAL ERROR: Cannot create area log file '".$arealogfile."': $!";

### >>>
my @a = getDirent($lProjectDataPath);
for ( @a ) {
 if ( $_ =~ m/^$speccode/i && -d "$lProjectDataPath/$_" ) {
  my %areas = ();
  my %lengths = ();
  my %sections = ();
  my $lBrainPath = $lProjectDataPath."/".$_;
  my $lBrain = $_;
  my $lSectionDistance = $lDistance;
  $lSectionDistance = loadSectionDistance($_,$species,$lDistance) if ( $lLoadDistance );
  $brains{$lBrain} = "";
  $lBrain =~ s/check_//;
  if ( defined($onlybrain) ) {
   ## print "checking $lBrain with $onlybrain...\n" if ( $verbose );
   next unless ( $onlybrain =~ m/^$lBrain$/ );
  }
  print "Processing '".$lBrain."'...\n" if ( $verbose );
  print FPAreaLogout "brain $lBrain...\n";
  my @sectionnumbers = ();
  my @xmlFiles = ();
  my $counter = 0;
  my @f = getDirent($lBrainPath);
  foreach my $lXMLFile (@f) {
   next unless ( $lXMLFile =~ m/.xml$/i );
   push(@sectionnumbers,getSectionNumber($lXMLFile));
   push(@xmlFiles,$lXMLFile);
  }
  my %sectionnumbersindex;
  @sectionnumbersindex{@sectionnumbers} = (0 .. $#sectionnumbers);
  my @sectionnumbers = sort { $a <=> $b } @sectionnumbers;
  foreach (@sectionnumbers) {
   my $lXMLFile = $xmlFiles[$sectionnumbersindex{$_}];
   my $sectionnumber = getSectionNumber($lXMLFile);
   if ( defined($onlysection) ) {
    next unless ( $onlysection==$sectionnumber );
   }
   print " + index: $_:$sectionnumbersindex{$_}, section: '$lBrain.$lXMLFile', ident: $sectionnumber...\n" if ( $verbose );
   print FPAreaLogout " + section '".$lXMLFile."', ident=$sectionnumber...\n";
   $sections{$sectionnumber} = $counter;
   $counter++;
   ### open xml file for reading
    my $areaname = "";
    my $lFile = $lBrainPath."/".$lXMLFile;
    my $lScanPoints = 0;
    my $xycoords = "";  ### NEU ###
    my %xydata = ();    ### NEU ###
    my @xcoords = ();
    my @ycoords = ();
    my %lAreas = ();
    my %lLengths = ();
    my $lArea = 0;
    my $lLength = 0;
    my $isOnlyInnerOuter = 0;
    ### loading contour data
    open(INFILE,"<$lFile") || printfatalerror "FATAL ERROR: Cannot open '".$lFile."' for reading: $!";
     while ( <INFILE> ) {
      if ( $_ =~ m/name=/ ) {
       if ( $_ =~ m/extra/ ) {
        ## nothing to do
       } else {
        ## getting strucname
        my @names = split(/ /,$_);
        foreach (@names) {
         if ( $_ =~ m/name/ ) {
          print "  > found name attribute '$_'...\n" if ( $verbose );
          my $start = 2;
          $areaname = $_;
          $areaname =~ s/name=//;
          $areaname =~ s/"//g;
          ## geht das immer so?
          # print " areaname[before]='$areaname'\n";
          my $oldareaname = $areaname;
          $isOnlyInnerOuter = 0;
          if ( $areaname =~ m/\_onlyinner/i || $areaname =~ m/\_onlyouter/i ) {
           print "   > found onlyinner/onlyouter structure...\n" if ( $verbose );
           $isOnlyInnerOuter = 1;
           $start = 3;
          }
          ### get clean areaname
          my @areanames = split(/_/,$areaname);
          my $dim = @areanames;
          # $areaname = "$areanames[$dim-2]_$areanames[$dim-1]";
          $areaname = "";
          for ( my $ndim=$dim-$start ; $ndim<$dim ; $ndim+=1 ) {
           # print " ndim=$ndim\n";
           $areaname .= "$areanames[$ndim]_";
          }
          chop($areaname);
          $areaname =~ s/\_L/\_l/ if ( $areaname =~ m/\_L/ );
          $areaname =~ s/\_R/\_r/ if ( $areaname =~ m/\_R/ );
          # print " areaname[before:after]='".$areaname."':'".$oldareaname."'\n";
         }
        }
       }
      } elsif ( $_ =~ m/Trace\>/i ) {
       ##my $num = @xcoords;
       $lLength += getTraceLength(\@xcoords,\@ycoords);
       $lArea += getArea(\@xcoords,\@ycoords) unless ( $isOnlyInnerOuter );
       ##my @center = getcentroid(\@xcoords,\@ycoords);
       ##$areas{$areaname} .= "$sectionnumber $lArea ";
       ##$lengths{$areaname} .= "$sectionnumber $lLength ";
       ## print "  end trace: dim=\"$num\" length=\"$lLength\" area=\"$lArea\"\n";
       $lScanPoints = 0;
       $xycoords .= ":";  ## add trace splitter for onlyinner/onlyouter analysis
      } elsif ( $_ =~ m/\<Trace/i ) {
       $lScanPoints = 1;
       @xcoords = ();
       @ycoords = ();
      } elsif ( $_ =~ m/\<Point/i ) {
       my @tmp = split(/\>/,$_);
       my @pointline = split(/\</,$tmp[1]);
       my @points = split(/ /,$pointline[0]);
       push(@xcoords,$points[0]);
       push(@ycoords,$points[1]);
       $xycoords .= "$points[0],$points[1] ";
      } elsif ( $_ =~ m/Structure\>/i ) {
       ## $areas{$areaname} .= "$sectionnumber $lArea ";
       # print ">>> $lFile - area[$areaname|$areaparity]=$lArea \n";
       # das ist leider zu einfach gedacht: es k\F6nnen auch onlyinner strukturen vorhanden sein,
       # die sich nicht innerhalb einer onlyouter struktur befinden !!! Diese duerfen nicht
       # abgezogen werden !!!
       if ( ! $isOnlyInnerOuter ) {
        $lAreas{$areaname} .= $lArea." ";
       } else {
        chop($xycoords); ## remove trace separator at the end
        print " + add xydata $xycoords to area $areaname...\n" if ( $verbose );
        $xydata{$areaname} = $xycoords;
       }
       $xycoords = "";
       $lArea = 0;
       ## $lengths{$areaname} .= "$sectionnumber $lLength ";
       $lLengths{$areaname} .= $lLength." ";
       $lLength = 0;
      }
     }
    close(INFILE);
    ### processing onlyinner/onlyouter data
    if ( keys(%xydata)>0 ) { 
     print FPAreaLogout "  > found structures with only inner/outer traces...\n";
     my @onlystructures = ();
     foreach my $areaname (sort(keys %xydata)) {
      my $structurename = cleanStructureName($areaname,1);
      push(@onlystructures,$structurename);
      print FPAreaLogout  "   + found onlyinner/onlyouter trace of structure ".$structurename."...\n";
     }
     @onlystructures = removeDoubleEntriesFromArray(@onlystructures);
     print FPAreaLogout "   > found ".scalar(@onlystructures)." unqiue structure(s) with onlyinner and onlyouter traces.\n";
     foreach my $onlystructure (@onlystructures) {
      my @onlyInnerDatas = ();
      my @onlyOuterDatas = ();
      foreach my $areaname (sort(keys %xydata)) {
       my $structurename = cleanStructureName($areaname,1);
       if ( $structurename =~ m/^$onlystructure$/ ) {
        my @traces = split(/\:/,$xydata{$areaname});
        print FPAreaLogout "    >>>> areaname: $areaname, traces=@traces\n" if ( $lDoDebug );
        if ( $areaname =~ m/\_onlyinner$/ ) {
         push(@onlyInnerDatas,@traces);
        } else {
         push(@onlyOuterDatas,@traces);
        }
       }
      }
      my $nOnlyInner = scalar(@onlyInnerDatas);
      my $nOnlyOuter = scalar(@onlyOuterDatas);
      print FPAreaLogout "  + found structure '$onlystructure' with $nOnlyInner onlyinner and $nOnlyOuter onlyouter structure traces...\n";
      # foreach structure in xmlfile
      if ( $nOnlyInner>0 && $nOnlyOuter==0 ) {
       print FPAreaLogout "   + processing onlyinner only overlay of structure $onlystructure...\n";
       foreach my $onlyInnerData (@onlyInnerDatas) {
        my $area2 = getArea2($onlyInnerData);
        print FPAreaLogout "    + adding area $area2 to structure $onlystructure...\n";
        $lAreas{$onlystructure} .= $area2." ";
       }
      } elsif ( $nOnlyInner==0 && $nOnlyOuter>0 ) {
       print FPAreaLogout "  + processing onlyouter only overlay of structure $onlystructure...\n";
       foreach my $onlyOuterData (@onlyOuterDatas) {
        my $area2 = getArea2($onlyOuterData);
        print FPAreaLogout "    + adding area $area2 to structure $onlystructure...\n";
        $lAreas{$onlystructure} .= $area2." ";
       }
      } elsif ( $nOnlyInner>0 && $nOnlyOuter>0 ) {
       ### looking for pairs A_i and A_j then we can use the formular: ||A_i-A_j||
       print FPAreaLogout "    + analyzing onlyinner/onlyouter overlap of structure $onlystructure...\n";
       ### getting pairs (this is experimental!!!)
       my %nOnlyInnerDataOverlap = ();
       my %nOnlyOuterDataOverlap = ();
       my $nOnlyInnerData = 0;
       foreach my $onlyInnerData (@onlyInnerDatas) {
        $nOnlyInnerData += 1;
        my $datastring1 = "";
        my @xydatas = split(/\ /,$onlyInnerData);
        foreach my $xydata (@xydatas) {
         $datastring1 .= $xydata.",";
        }
        $datastring1 .= $xydatas[0];
        my $nOnlyOuterData = 0;
        foreach my $onlyOuterData (@onlyOuterDatas) {
         my @xydatas_oo = split(/\ /,$onlyOuterData);
         if ( scalar(@xydatas_oo)>0 ) {
          $nOnlyOuterData += 1;
          my $datastring2 = "";
          foreach my $xydata_oo (@xydatas_oo) {
           $datastring2 .= $xydata_oo.",";
          }
          $datastring2 .= $xydatas_oo[0];
          ### computing overlay
          my $result = `pathintersection --path1 $datastring1 --path2 $datastring2`;
          chomp($result);
          print FPAreaLogout "     + result between onlyinner trace $nOnlyInnerData and onlyouter trace $nOnlyOuterData: $result\n";
          if ( $result =~ m/^is_enclosed/ ) {
           my $nOnlyOuterDataIndex = $nOnlyOuterData-1;
           my $nOnlyInnerDataIndex = $nOnlyInnerData-1;
           # $nOnlyOuterDataOverlap{$nOnlyOuterDataIndex} = 1;
           push(@{$nOnlyOuterDataOverlap{$nOnlyOuterDataIndex}},$nOnlyInnerDataIndex);
           push(@{$nOnlyInnerDataOverlap{$nOnlyInnerDataIndex}},$nOnlyOuterDataIndex);
          }
         }
        }
       }
       if ( $lDoDebug ) { 
        printHashArray(\%nOnlyOuterDataOverlap,*FPAreaLogout,"outer overlap: ");
        printHashArray(\%nOnlyInnerDataOverlap,*FPAreaLogout,"inner overlap: ");
       }
       while ( my ($key,$values_ptr) = each(%nOnlyOuterDataOverlap) ) {
        my @outeroverlayvalues = @{$values_ptr};
        print FPAreaLogout "      + 1st level checking: $key -> (@outeroverlayvalues)\n";
        if ( scalar(@outeroverlayvalues)==1 ) {
         my $innerId = $outeroverlayvalues[0];
         if ( exists($nOnlyInnerDataOverlap{$innerId}) ) {
          my @inneroverlayvalues = @{$nOnlyInnerDataOverlap{$innerId}};
          print FPAreaLogout "       + 2nd level checking: $innerId -> (@inneroverlayvalues)\n";
          if ( scalar(@inneroverlayvalues)==1 && $inneroverlayvalues[0]==$key ) {
           print FPAreaLogout "        + subtracting from outer area $key the area of inner trace $innerId...\n";
           my $outerarea = getArea2($onlyOuterDatas[$key]);
           my $innerarea = getArea2($onlyInnerDatas[$innerId]);
           my $diffarea = $outerarea-$innerarea;
           $diffarea *= -1 if ( $diffarea<0 );
           print FPAreaLogout "          => adding area $diffarea to structure $onlystructure.\n";
           $lAreas{$onlystructure} .= $diffarea." ";
          }
         }
        }
       }
       while ( my ($key,$values_ptr) = each(%nOnlyOuterDataOverlap) ) {
        my @overlayvalues = @{$values_ptr};
        if ( scalar(@overlayvalues)>1 ) {
         my $outerarea = getArea2($onlyOuterDatas[$key]);
         print FPAreaLogout "      + subtracting from outer area $key=$outerarea the area values of inner traces (@overlayvalues)...\n";
         my $sumarea = 0;
         foreach my $overlayvalue (@overlayvalues) {
          my $innerarea = getArea2($onlyInnerDatas[$overlayvalue]);
          print FPAreaLogout "       + area of inner trace $overlayvalue: $innerarea\n";
          $sumarea += $innerarea;
         }
         my $totalarea = $outerarea-$sumarea;
         print FPAreaLogout "        => adding area $totalarea to structure $onlystructure.\n";
         $lAreas{$onlystructure} .= $totalarea." ";
        }
       }
       while ( my ($key,$values_ptr) = each(%nOnlyInnerDataOverlap) ) {
        my @overlayvalues = @{$values_ptr};
        if ( scalar(@overlayvalues)>1 ) {
         my $innerarea = getArea2($onlyInnerDatas[$key]);
         print FPAreaLogout "      + subtracting from inner area $key=$innerarea the area values of outer traces (@overlayvalues)...\n";
         my $sumarea = 0;
         foreach my $overlayvalue (@overlayvalues) {
          my $outerarea = getArea2($onlyOuterDatas[$overlayvalue]);
          print FPAreaLogout "       + area of outer trace $overlayvalue: $outerarea\n";
          $sumarea += $outerarea;
         }
         my $totalarea = $innerarea-$sumarea;
         print FPAreaLogout "        => adding area $totalarea to structure $onlystructure.\n";
         $lAreas{$onlystructure} .= $totalarea." ";
        }
       }
       ### checking whether any non-mixed onlyouter (or onlyinner!!!) data  are missing ...
       print FPAreaLogout  "       checking whether non-overlapping onlyouter data exist...\n";
       my $nSingleOnlyOuterStructures = 0;
       for ( my $index=0 ; $index<scalar(@onlyOuterDatas) ; $index++ ) {
        if ( !exists($nOnlyOuterDataOverlap{$index}) ) {
         my $area = getArea2($onlyOuterDatas[$index]);
         print FPAreaLogout "        + found non-overlapping onlyouter structure ".scalar($index+1)."...\n";
         print FPAreaLogout "         => adding area $area to structure $onlystructure.\n";
         $lAreas{$onlystructure} .= $area." ";
         $nSingleOnlyOuterStructures += 1;
        }
       }
       print FPAreaLogout "        + found $nSingleOnlyOuterStructures structure(s).\n";
      }
     }
    }
    ### join data
    foreach my $key (sort(keys %lAreas)) {
     my $totalarea = 0;
     chop($lAreas{$key});
     my @values = split(/\ /,$lAreas{$key});
     foreach (@values) { $totalarea += $_; }
     $areas{$key} .= "$sectionnumber $totalarea ";
     print FPAreaLogout "   + AREA: structure: '$key' value: '$lAreas{$key}' -> totalarea: $totalarea\n";
    }
    ## exit(1);
    foreach my $key (sort(keys %lLengths)) {
     my $totallength = 0;
     chop($lLengths{$key});
     my @values = split(/\ /,$lLengths{$key});
     foreach (@values) { $totallength += $_; }
     $lengths{$key} .= "$sectionnumber $totallength ";
     ## print "LENGTH: key: '$key' value: '$lLengths{$key}' -> totallength: $totallength\n";
    }
    ### end
  }
  ## save data
   ## preparing excel worksheet
   my $worksheet = $workbook->add_worksheet($lBrain);
   if ( $lDoPixels ) {
    $worksheet->write(0,0,"Area [pixels]",$format);
   } else {
    $worksheet->write(0,0,"Area [sqmm]",$format);
   }
   if ( $nosvn ) {
    $worksheet->write(1,0,"section",$format);
   } else {
    $worksheet->write(1,0,"section - revision",$format);
   }
   my $column = 1;
   my $row = 2;
   my $boffset = 0;
   my $lVolOffset = 0;
   ### write section numbers of each brain
   foreach my $key (keys %sections) {
    my $pos = 2+$sections{$key};
    if ( $nosvn ) {
     $worksheet->write($pos,0,$key,$format);
    } else {
     my $revision = getRevision($lProjectName,$lBrain,$key,$lContourReconPath,$lDoDebug);
     $worksheet->write($pos,0,"$key - $revision",$format);
    }
    $row++;
   }
   unless ( $basic ) {
    ## print intersection info
    $worksheet->write($row+1,0,"Intersection [orig:lin:nlin]",$format);
    $worksheet->write($row+2,0,"critical",$format2);
    $worksheet->write($row+3,0,"non-critical",$format2);
    ## print alteration info
    $worksheet->write($row+9,0,"Alteration [x/orig]",$format);
    $worksheet->write($row+10,0,"lin",$format2);
    $worksheet->write($row+11,0,"nlin",$format2);
    ## adapt offset parameters
    $lVolOffset = 4;
    $boffset = 8;
   }
   ## print volume info
   $worksheet->write($row+1+$lVolOffset,0,"Volume [cmm]",$format);
   $worksheet->write($row+2+$lVolOffset,0,"original",$format2);
   $worksheet->write($row+3+$lVolOffset,0,"corrected",$format2);
   my $lStatsOffset = 0;
   ## print volume change info
   if ( $lShowVolumeAlteration ) {
    $worksheet->write($row+5+$boffset,0,"Volume change [x/orig]",$format);
    if ( $float ) {
     $worksheet->write($row+6+$boffset,0,"assembleF gaussian",$format2);
    } else {
     $worksheet->write($row+6+$boffset,0,"assemble gaussian",$format2);
    }
    $lStatsOffset += 3;
   }
   ## print contour topology
   if ( $lShowTopology ) {
    $worksheet->write($row+5+$boffset+$lStatsOffset,0,"Contour topology",$format);
    $worksheet->write($row+6+$boffset+$lStatsOffset,0,"components",$format2);
    $worksheet->write($row+7+$boffset+$lStatsOffset,0,"genus (=1?)",$format2);
    $lStatsOffset += 4;
   }
   if ( $lShowSurface ) {
    $worksheet->write($row+5+$boffset+$lStatsOffset,0,"Inner Surface [sqmm]",$format);
    $worksheet->write($row+6+$boffset+$lStatsOffset,0," original",$format2);
    $worksheet->write($row+7+$boffset+$lStatsOffset,0," corrected",$format2);
    $worksheet->write($row+8+$boffset+$lStatsOffset,0,"Outer Surface [sqmm]",$format);
    $worksheet->write($row+9+$boffset+$lStatsOffset,0," original",$format2);
    $worksheet->write($row+10+$boffset+$lStatsOffset,0," corrected",$format2);
    $lStatsOffset += 7;
   }
   if ( $lShowDistance ) {
    $worksheet->write($row+5+$boffset+$lStatsOffset,0,"Distance [mm]",$format);
    $worksheet->write($row+6+$boffset+$lStatsOffset,0,"original",$format2);
    $worksheet->write($row+7+$boffset+$lStatsOffset,0,"corrected",$format2);
    $lStatsOffset += 4;
   }
   $worksheet->set_column(0,0,25);
   ### write area data
   foreach my $key (sort(keys %areas)) {
    my $cleankey = getCheckedStructureName($key);
    if ( $#procareas>=0 ) {
     my $foundarea = 0;
     foreach my $lProcArea (@procareas) {
      if ( $cleankey eq getCheckedStructureName($lProcArea) ) {
       $foundarea = 1;
       last;
      }
     }
     next unless ( $foundarea );
    }
    $worksheet->set_column(1,$column,11);
    $worksheet->write(1,$column,$key,$format);
    my $lAreaCode = $areas{$key};
    my @areas = split(/ /,$lAreaCode);
    my $lLengthCode = $lengths{$key};
    my @lengths = split(/ /,$lLengthCode);
    my $dim = @areas;
    my $lVolume = 0;
    my $lArea = 0;
    my $lLastArea = 0;
    my $lLastPos = 0;
    ## get pre-calculated inner and outer surface
    my $lSurfaceDataPath = $lProjectPath."/cnt/".$lDataType."/".$lBrain;
    my $lInnerSurface = "";
    my $lOuterSurface = "";
    if ( $lShowSurface ) {
     $lInnerSurface = getElementFromSurfaceInfoFile("$lSurfaceDataPath/${lBrain}_${key}_inner.surf","surface",$surfGenMethod);
     $lOuterSurface = getElementFromSurfaceInfoFile("$lSurfaceDataPath/${lBrain}_${key}_outer.surf","surface",$surfGenMethod);
    }
    ## print intersection info
    unless ( $basic ) {
     my @ivalues = getCriticalIntersectionsFromFile("self",$lProjectName,$lBrain,$key,$lContourReconPath,$pedantic);
     if ( $ivalues[0]>0 || $ivalues[1]>0 || $ivalues[2]>0 ) {
      $worksheet->write($row+2,$column,"$ivalues[0]:$ivalues[1]:$ivalues[2]",$format4);
     } else {
      $worksheet->write($row+2,$column,"$ivalues[0]:$ivalues[1]:$ivalues[2]",$format);
     }
     @ivalues = getCriticalIntersectionsFromFile("all",$lProjectName,$lBrain,$key,$lContourReconPath,$pedantic);
     $worksheet->write($row+3,$column,"$ivalues[0]:$ivalues[1]:$ivalues[2]",$format);
    }
    ## calc volume
    my $lTotalDelta = 0;
    for ( my $i=0 ; $i<$dim ; $i+=2 ) {
     $lArea = $areas[$i+1];
     print " DEBUG - section[$areas[$i]]=$sections{$areas[$i]} area=$lArea volume=$lVolume, key=$key\n" if ( $lDoDebug );
     if ( $i<$dim-1 && $areas[$i]!=$areas[$i+2] ) {
      my $lRow = 2+$sections{$areas[$i]};
      if ( isCriticalContour($lBrainPath,$areas[$i],$key) ) {
       $worksheet->write($lRow,$column,$lArea,$format1red);
      } else {
       $worksheet->write($lRow,$column,$lArea,$format1);
      }
      if ( $lDoSimpson==0 && $lDoPixels==0 ) {
        ## that's cavalieri
        my $lDelta = 60;
        if ( $i+2<$dim ) {
         $lDelta = $areas[$i+2]-$areas[$i];
         $lTotalDelta += $lDelta;
        } else {
         if ( $dim-2!=0 ) {
          $lDelta = 2*$lTotalDelta/($dim-2);
         } else {
          $lDelta = 0;
         }
        }
        print " DEBUG:  $key: area[$lArea] delta[$lDelta]\n" if ( $lDoDebug );
        $lVolume += $lDelta*$lArea;
      } elsif ( $lDoPixels==1 ) {
       $lVolume += $lArea;
      } else {
       if ( $lLastArea!=0 ) {
        my $lDelta = $areas[$i]-$lLastPos;
        $lVolume += 2*$lLastArea*$lDelta;
       }
      }
      $lLastPos = $areas[$i];
      $lLastArea = $lArea;
     }
    }
    if ( $lDoPixels==1 ) {
     $lVolume *= 60*0.02*25.4*25.4/($lResolution*$lResolution);
    } else {
     $lVolume *= $lSectionDistance;
    }
    $worksheet->write($row+2+$lVolOffset,$column,$lVolume,$format);
    my $lCorrectedVolume = $lVolume*$factors{$lBrain};
    $worksheet->write($row+3+$lVolOffset,$column,$lCorrectedVolume,$format);
    unless ( $basic ) {
     ## print volume alteration
     my $lOrigVolume = getCavalieriVolumeFromFile("orig",$lProjectName,$lBrain,$key,$lContourReconPath,$pedantic);
     if ( $lOrigVolume>0.0 ) {
      my $lLinVolumeAlteration = getCavalieriVolumeFromFile("lin",$lProjectName,$lBrain,$key,$lContourReconPath,$pedantic)/$lOrigVolume;
      $worksheet->write($row+2+$boffset,$column,$lLinVolumeAlteration,$format1);
      my $lNLinVolumeAlteration = getCavalieriVolumeFromFile("nlin",$lProjectName,$lBrain,$key,$lContourReconPath,$pedantic)/$lOrigVolume;
      $worksheet->write($row+3+$boffset,$column,$lNLinVolumeAlteration,$format1);
     } else {
      $worksheet->write($row+2+$boffset,$column,"undefined",$format4);
      $worksheet->write($row+3+$boffset,$column,"undefined",$format4);
     }
    }
    ## more infos
    $lStatsOffset = 0;
    if ( $lShowVolumeAlteration ) {
     my $volumechange = getAssembleVolumeChange($lProjectName,$lBrain,$key);
     $worksheet->write($row+6+$boffset+$lStatsOffset,$column,$volumechange,$format);
     $lStatsOffset += 3;
    }
    if ( $lShowTopology ) {
     ## print contour topology info
     my @topoValues = getNLinContourTopologyValues($lProjectName,$lBrain,$key);
     $worksheet->write($row+6+$boffset+$lStatsOffset,$column,$topoValues[0],$format);
     $worksheet->write($row+7+$boffset+$lStatsOffset,$column,$topoValues[1],$format);
     $lStatsOffset += 4;
    }
    if ( $lShowSurface ) {
     ## print inner and outer surface values
     $lInnerSurface *= 0.02*25.4/$lResolution;
     $worksheet->write($row+6+$boffset+$lStatsOffset,$column,$lInnerSurface,$format);
     my $lCorrectedInnerSurface = $lInnerSurface*($factors{$lBrain}**(2/3));
     $worksheet->write($row+7+$boffset+$lStatsOffset,$column,$lCorrectedInnerSurface,$format);
     $lOuterSurface *= 0.02*25.4/$lResolution;
     $worksheet->write($row+9+$boffset+$lStatsOffset,$column,$lOuterSurface,$format);
     my $lCorrectedOuterSurface = $lOuterSurface*($factors{$lBrain}**(2/3));
     $worksheet->write($row+10+$boffset+$lStatsOffset,$column,$lCorrectedOuterSurface,$format);
     $lStatsOffset += 7;
    }
    if ( $lShowDistance ) {
     ## print inner/outer distance values
     my $lDistance2 = 2*$lVolume;
     if ( ($lInnerSurface+$lOuterSurface)==0 ) {
      $lDistance2 = 0;
     } else {
      $lDistance2 /= ($lInnerSurface+$lOuterSurface);
     }
     $worksheet->write($row+6+$boffset+$lStatsOffset,$column,$lDistance2,$format);
     my $lCorrectedDistance = $lDistance2*($factors{$lBrain}**(1/3));
     $worksheet->write($row+7+$boffset+$lStatsOffset,$column,$lCorrectedDistance,$format);
     $lStatsOffset += 4;
    }
    $strucs{$key} = "";
    $brains{$lBrain} .= "$key $lVolume $lCorrectedVolume ";
    # print " *** brain[".$lBrain."]=".$brains{$lBrain}."\n";
    $column++;
   }
   ### brain info line
   $row += 5+$boffset;
   $row += 3 if ( $lShowVolumeAlteration );
   $row += 7 if ( $lShowSurface );
   $row += 4 if ( $lShowTopology );
   $row += 4 if ( $lShowDistance );
   $worksheet->write($row,2,"Brain",$format);
   $worksheet->write($row,0,"Parameter",$format);
   $row++;
   ##$worksheet->write($row,0,"Brain",$format2);
   ##$worksheet->write($row,1,$lBrain,$format1);
   ##$row++;
   $worksheet->write($row,2,"Name",$format2);
   $worksheet->write($row,3,$lBrain,$format1);
   $worksheet->write($row,0,"Datatype",$format2);
   $worksheet->write($row,1,$lDataType,$format1);
   $row++;
   $worksheet->write($row,2,"Gender",$format2);
   $worksheet->write($row,3,$genders{$lBrain},$format1);
   $worksheet->write($row,0,"Shrinkage Factor",$format2);
   $worksheet->write_number($row,1,$factors{$lBrain},$format1);
   $row++;
   $worksheet->write($row,2,"Age",$format2);
   $worksheet->write($row,3,$ages{$lBrain},$format1b);
   $worksheet->write($row,0,"Resolution [dpi]",$format2);
   $worksheet->write_number($row,1,$lResolution,$format1b);
   $row++;
   $worksheet->write($row,2,"Ident",$format2);
   $worksheet->write($row,3,$brainidents{$lBrain},$format1b);
   $worksheet->write($row,0,"Distance [mm]",$format2);
   $worksheet->write_number($row,1,$lSectionDistance,$format1);
   $row++;
   $worksheet->write($row,2,"Orientation",$format2);
   $worksheet->write($row,3,getTableFieldFromAtlasDatabase($dbh,"atlas.pmbrains","sectionplane","name='$lBrain'"),$format1);
   $worksheet->write($row,0,"nested",$format2);
   if ( $lIsNested ) {
    $worksheet->write($row,1,"true",$format1);
   } else {
    $worksheet->write($row,1,"false",$format1);
   }
   $row++;
   $worksheet->write($row,0,"closed",$format2);
   if ( $lIsClosed ) {
    $worksheet->write($row,1,"true",$format1);
   } else {
    $worksheet->write($row,1,"false",$format1);
   }
   $row++;
   $worksheet->write($row,0,"volume method",$format2);
   if ( $lDoPixels ) {
    $worksheet->write($row,1,"pixelcount",$format1);
   } elsif ( $lDoSimpson ) {
    $worksheet->write($row,1,"simpson",$format1);
   } else {
    $worksheet->write($row,1,"cavalieri",$format1);
   }
   if ( $lShowSurface ) {
    $row++;
    $worksheet->write($row,0,"triangulator",$format2);
    $worksheet->write($row,1,$surfGenMethod,$format1);
   }
 }
}
close(FPAreaLogout);
## last sheet
my $worksheet = $workbook->add_worksheet("Summary");
$worksheet->set_column(0,0,17);
 ### save orig volume
 $worksheet->write(0,0,"Original Volume",$format);
 my $row = 2;
 my $lNumStrucs = 0;
 foreach my $key (sort(keys %strucs)) {
  $worksheet->write($row,0,$key,$format);
  $strucs{$key} = $row;
  $lNumStrucs++;
  $row++;
 }
 $worksheet->write($row,0,"Sum",$format);
 $row++;
 ### save shrinkage factors
 my $lShrinkageRow = $row+1;
 $worksheet->write($lShrinkageRow,0,"Shrinkage factors",$format);
 ### save data
 my $column = 1;
 foreach my $key (sort(keys %brains)) {
  ## print "*** brain[$key]=".$brains{$key}."\n";
  $worksheet->set_column(1,$column,11);
  $worksheet->write(1,$column,$key,$format);
  $worksheet->write($lShrinkageRow,$column,$factors{$key},$format);
  my $volumes =  $brains{$key};
  my @datas = split(/ /,$volumes);
  my $dim = @datas;
  my $sum = 0.0;
  for ( my $i=2 ; $i<=2+$lNumStrucs ; $i++ ) {
   $worksheet->write($i,$column,"",$format3);
  }
  for ( my $i=0 ; $i<$dim ; $i+=3 ) {
   $worksheet->write($strucs{$datas[$i]},$column,$datas[$i+1],$format3);
   $sum += $datas[$i+1];
  }
  if ( $dim!=0 ) {
   $sum /= $dim/3;
  } else {
   $sum = -1;
  }
  $worksheet->write($row-1,$column,$sum,$format1);
  $column++;
 }
 $worksheet->write(1,$column,"Mean",$format);
 $worksheet->write(1,$column+1,"Std",$format);
 ### save corrected volume
 $row += 3;
 $worksheet->write($row,0,"Corrected Volume",$format);
 $row++;
 my $orow = 3;
 foreach my $key (sort(keys %strucs)) {
  $worksheet->write($row,0,$key,$format);
  $strucs{$key} = $row;
  $row++;
  if ( ! $lSkipFormular ) {
    ## get last character
    my $numbrains = keys(%brains);
    my $lastchar = chr($numbrains+ord("B")-1);
    ## for original volume
    my $lAverage = "=AVERAGE(B$orow:$lastchar$orow)";
    $worksheet->write_formula($orow-1,$column,$lAverage,$format1);
    my $lStdDev = "=STDEV(B$orow:$lastchar$orow)";
    $worksheet->write_formula($orow-1,$column+1,$lStdDev,$format1);
    $orow++;
    ## for corrected volume
    my $lAverage = "=AVERAGE(B$row:$lastchar$row)";
    $worksheet->write_formula($row-1,$column,$lAverage,$format1);
    my $lStdDev = "=STDEV(B$row:$lastchar$row)";
    $worksheet->write_formula($row-1,$column+1,$lStdDev,$format1);
  }
 }
 $worksheet->write($row,0,"Sum",$format);
 my $column = 1;
 foreach my $key (sort(keys %brains)) {
  my $volumes =  $brains{$key};
  my $sum = 0.0;
  my @datas = split(/ /,$volumes);
  my $dim = @datas;
  for ( my $i=$lShrinkageRow+3 ; $i<=$lShrinkageRow+3+$lNumStrucs ; $i++ ) {
   $worksheet->write($i,$column,"",$format3);
  }
  for ( my $i=0 ; $i<$dim ; $i+=3 ) {
   $worksheet->write($strucs{$datas[$i]},$column,$datas[$i+2],$format3);
   $sum += $datas[$i+2];
  }
  if ( $dim!=0 ) {
   $sum /= $dim/3;
  } else {
   $sum = -1;
  }
  $worksheet->write($row,$column,$sum,$format1);
  $column++;
 }
## move/copy excel file into '$project/docs' and 'allareas/docs/volume' directory. before we have to close the excel workbook!!!
$workbook->close();
$lProjectPath .= "/docs";
createOutputPath($lProjectPath);
move($lExcelFileName,$lProjectPath."/".basename($lExcelFileName)) || printfatalerror "FATAL ERROR: Could not move excel file '".$lExcelFileName."': $!";
my $allAreasVolumePath = $lContourReconPath."/allareas/docs/volumes";
if ( -d $allAreasVolumePath ) {
 copy($lProjectPath."/".$lExcelFileName,$allAreasVolumePath) ||
            printfatalerror "FATAL ERROR: Could not copy excel file: $!";
}
print "Saved Excel file '".$lProjectPath."/".basename($lExcelFileName)."'.\n" if ( $verbose );
$dbh->disconnect();
## save volume values
my $volfilename = createOutputPath($lProjectPath."/values");
$volfilename .= "/volume_cavalieri_orig.info";
open(FPout,">$volfilename") || printfatalerror "FATAL ERROR: Cannot create volume info file '".$volfilename."': $!";
 foreach my $key (sort(keys %brains)) {
  print FPout $key." ".$brains{$key}."\n";
 }
close(FPout);
print "Saved volume info file '".$volfilename."'.\n" if ( $verbose );
######################## end of main part #########################################

$dbh->disconnect() if ( defined($dbh) );
