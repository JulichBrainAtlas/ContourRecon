# Creating maximum probability map of the volume or on the surface for a single project
##################################################################################################################################

### >>>
use strict;
use POSIX;
use File::Copy;
use File::Path;
use File::stat;
use File::Basename;
use Getopt::Long;
use Term::ANSIColor;

### local local modules
die "FATAL ERROR: Missing global path variable HITHOME linked to HICoreTools." unless ( defined($ENV{HITHOME}) );
use lib $ENV{HITHOME}."/src/perl";
use hitperl;
use hitperl::atlas;
use hitperl::database;
use hitperl::ontology;
use hitperl::fsurfmesh;
use hitperl::colormap;
use hitperl::mpmtool;
use hitperl::image;
use hitperl::repos;
use hitperl::rtlog;

### inits
my $ATLASPATH = $ENV{ATLASPATH};
printfatalerror "FATAL ERROR: Invalid atlas path '".$ATLASPATH."': $!" unless ( -d $ATLASPATH );
my $DATABASEPATH = $ENV{DATABASEPATH};
printfatalerror "FATAL ERROR: Invalid database path '".$DATABASEPATH."': $!" unless ( -d $DATABASEPATH );
my $canvas = "data/canvas/canvas_black4pdf.png";
my $GLOBALCOLORMAPFILE = "data/colors.cmap";
my @gcolors= ();
my $timestamp = sprintf "%06x",int(rand(100000));
my $tmp = "tmp/tmp".$timestamp;

### >>>
sub getReferenceBrainName {
 my ($name,$verbose,$debug) = @_;
 my @elements = split(/\,/,$name);
 my %info = ();
 $info{"name"} = $elements[0].$elements[1];
 if ( $elements[0] =~ m/^Colin/i ) {
  $info{"short"} = lc($elements[0]);
 } else {
  $info{"short"} = lc($info{"name"});
 }
 return %info;
}

###
sub getAreaDirs {
 my ($lPath,$filter,$cside,$validstructures_ptr) = @_;
 my @indatas = getDirent($lPath);
 my @areas = ();
 if ( defined($validstructures_ptr) ) {
  my @validstructures = @{$validstructures_ptr};
  foreach my $apath (@indatas) {
   next unless ( -d "$lPath/$apath" );
   ## print "  ++\n";
   if ( $apath =~ m/\_${filter}/i && $apath =~ m/_${cside}_/i ) {
    ## print "  ++>>>\n";
    foreach my $structure (@validstructures) {
     next if ( $structure =~ m/_l$/ );
     $structure =~ s/\_r$//i;
     if ( $apath =~ m/$structure/i ) {
      push(@areas,$apath);
      last;
     }
    }
   }
  }
 } else {
  foreach (@indatas) {
   if ( $_ =~ m/\_${filter}/i && $_ =~ m/_${cside}_/i ) {
    push(@areas,$_);
   }
  }
 }
 return @areas;
}

sub xmlGetElement {
  my ($line,$field) = @_;
  my $found = 0;
  my @elements = split(/\"/,$line);
  foreach my $element (@elements) {
    ## print "element: $element\n";
    if ( $found ) {
      return $element;
    } elsif ( $element =~ m/$field/i ) {
      $found = 1;
    }
  }
  return "";
}

sub loadGlobalColorFile {
  my $colorfile = $GLOBALCOLORMAPFILE;
  open(IN,"<$colorfile") || printfatalerror "FATAL ERROR: Cannot open color file '".$colorfile."': $!";
  while ( <IN> ) {
    chomp($_);
    my @colors = split(/\ /,$_);
    my $ncolors = @colors;
    next if ( $ncolors!=3 );
    next if ( $colors[0]+$colors[1]+$colors[2]==0 );
    push(@gcolors,$_);
  }
  close(IN);
  my $ngcolors = @gcolors;
  printfatalerror "FATAL ERROR: Cannot find any colors in '".$colorfile,"': $!" if ( $ngcolors==0 );
}

# check whether a color has already been used
sub haveColor {
  my ($color,$ref_to_colors,$ref_to_indices) = @_;
  my @colors = @{$ref_to_colors};
  my @indices = @{$ref_to_indices};
  foreach my $index (@indices) {
    return 1 if ( $colors[$index]==$color );
  }
  return 0;
}

sub checkColor {
  my ($color,$ref_to_colors,$ref_to_indices) = @_;
  my @colors = @{$ref_to_colors};
  my @indices = @{$ref_to_indices};
  foreach my $index (@indices) {
   if ( $colors[$index]==$color ) {
    printwarning "WARNING: Duplicated color found.\n";
    my $ngcolors = @gcolors;
    loadGlobalColorFile() if ( $ngcolors==0 );
    foreach my $gcolor (@gcolors) {
     if ( haveColor($gcolor,\@colors,\@indices)==0 ) {
      return $gcolor;
     }
    }
    printwarning "WARNING: Cannot find any replacement color for '$color'.\n";
    return $color;
   }
  }
  return $color;
}

sub xml2colorfile {
  my ($xmlfile,$pmapfile,$cmapfile,$unique) = @_;
  ### setup color vector
  my @colors = ();
  for ( my $i=0 ; $i<256 ; $i++ ) {
     push(@colors,"255 255 255");
  }
  ### open file xml file
  my @indices = ();
  my @strucnames = ();
  open(fp,"<$xmlfile") || printfatalerror "FATAL ERROR: Cannot open '".$xmlfile."': $!";
  while ( <fp> ) {
    my $line = $_;
    next unless ( $line =~ m/label/i );
    my $index = xmlGetElement($line,"index");
    my $color = xmlGetElement($line,"color");
    $color = checkColor($color,\@colors,\@indices) if ( $unique );
    push(@indices,$index);
    $colors[$index] = $color;
    $strucnames[$index] = getXMLValue($line);
  }
  close(fp);
  ### create cmap file
  my $nverts = 0;
  open(fpin,"<$pmapfile") || printfatalerror "FATAL ERROR: Cannot open '".$pmapfile."': $!";
  while ( <fpin> ) {
    $nverts++;
  }
  close(fpin);
  open(fpout,">$cmapfile") || printfatalerror "FATAL ERROR: Cannot create '".$cmapfile."': $!";
  print fpout "RGB\n";
  print fpout "$nverts\n";
  open(fpin,"<$pmapfile") || die "FATAL ERROR: Cannot open '".$pmapfile."': $!";
  while ( <fpin> ) {
    my @rgb = split(/ /,$colors[$_]);
    my $red = $rgb[0]/255;
    my $green = $rgb[1]/255;
    my $blue = $rgb[2]/255;
    print fpout "$red $green $blue\n";
  }
  close(fpin);
  close(fpout);
  ### create cmap info file
  my $cmapinfofile = $cmapfile;
  $cmapinfofile =~ s/\.vcol/\.dat/i;
  open(fpout,">$cmapinfofile") || printfatalerror "FATAL ERROR: Cannot create '".$cmapinfofile."': $!";
  foreach my $index (@indices) {
   print fpout "$strucnames[$index] $colors[$index]\n";
  }
  close(fpout);
  return $cmapinfofile;
}

sub savecofffile {
 my ($surfoutpath,$refBrainMeshFile,$colFile,$project) = @_;
 my $refFileName = basename($refBrainMeshFile);
 $refFileName =~ s/.off//i;
 my $outfilename = $surfoutpath."/".$refFileName."_mpm_".$project.".off";
 my $haveHeader = 0;
 my $haveDims = 0;
 open(FPout,">$outfilename") || die "FATAL ERROR: Cannot create '".$outfilename."': $!";
  open(FPin,"<$refBrainMeshFile") || printfatalerror "FATAL ERROR: Cannot open '".$refBrainMeshFile."' for reading: $!";
   while ( <FPin> ) {
    next if ( $_ =~ m/^#/ );
    chomp($_);
    print FPout "C$_\n";
   }
  close(FPin);
 close(FPout);
 exit(1);
}

### >>>
sub clusterLabelData {
 my ($datoutfile,$meshreffile,$vcoloutfile,$verbose,$debug) = @_;
 return $vcoloutfile if ( ! -e $datoutfile || ! -e $meshreffile || ! -e $vcoloutfile );
 my $datoutclsfile = $datoutfile;
 $datoutclsfile =~ s/\.dat$/_maxcluster.cluster/i;
 my $opts = "--largest --rawlabel";
 $opts .= " --verbose" if $verbose;
 if ( $datoutfile =~ m/_b_/ ) {
  ## not yet ....
  #my $sidefile = $meshreffile;
  #$sidefile =~ s/.off/_specs_left.dat/i;
  #print ">>> meshreffile[$meshreffile], sidespec[$sidefile].\n";
  #exit(1);
  return $vcoloutfile;
 } else {
  ssystem("hitMeshLabelCluster $opts --input $meshreffile --label $datoutfile --output $datoutclsfile",$debug);
 }
 return $vcoloutfile unless ( -e $datoutclsfile );
 ## loading label index file
 open(FPin,"<$datoutclsfile") || printfatalerror "FATAL ERROR: Cannot open cluster file '".$datoutclsfile."' for reading: $!";
  my @indices = ();
  my $nverts = <FPin>;
  chomp($nverts);
  while ( <FPin> ) {
   chomp($_);
   push(@indices,$_);
  }
 close(FPin);
 ## open vertex color file
 my $vcolclsfile = $vcoloutfile;
 $vcolclsfile =~ s/.vcol/_maxcluster.vcol/i;
 open(FPout,">$vcolclsfile") || printfatalerror "FATAL ERROR: Cannot create '".$vcolclsfile."': $!";
  print FPout "# maximum cluster\n";
  print FPout "RGB\n";
  print FPout "$nverts\n";
  open(FPin,"<$vcoloutfile") || printfatalerror "FATAL ERROR: Cannot open '".$vcoloutfile."' for reading: $!";
   while ( <FPin> ) {
    next if ( $_ =~ m/^#/ );
    my $nnverts = <FPin>;
    my $n = 0;
    while ( <FPin> ) {
     if ( $indices[$n] ) {
      print FPout $_;
     } else {
      print FPout "1.000000 1.000000 1.000000\n";
     }
     $n = $n+1;
    }
   }
  close(FPin);
 close(FPout);
 return $vcolclsfile;
}

### >>>
# correct misclassified holes in a mpm data set
# does NOT correct black (background) holes in a mpm data set
sub createFilledHolesDataset {
 my ($infilename,$side,$verbose,$overwrite,$debuglevel) = @_;
 ### (original code is in '$HOME/Partners/BenSigl/outcome/mpm/cleanmpm.pl')
  my $outcfilename = "mpmtable_lnormalized_".$side;
  my @outfiles = ();
  my $nonzeroliststr = `hitHistogram -i $infilename -nonzero:list -stdout`;
  my @nonzeros = split("\n",$nonzeroliststr);
  foreach my $i (@nonzeros) {
   next if ( $i==0 );
   my $outfilename = $outcfilename."_value0".$i.".nii.gz";
   if ( ! -e $outfilename || $overwrite ) {
    ssystem("hitThreshold -f -i $infilename -g $i -o $outfilename",$debuglevel);
    print " + extracted area volume file '".$outfilename."'...\n" if ( $verbose );
   }
   my $outlabelfilename = $outfilename;
   $outlabelfilename =~ s/\.nii\.gz/\_maxcomponent\.nii\.gz/;
   if ( ! -e $outlabelfilename || $overwrite ) {
    ssystem("itkLabelVolume -i $outfilename -o $outlabelfilename -v --apply --ignoreless 1 -x",$debuglevel);
    ssystem("fslcpgeom $infilename $outlabelfilename",$debuglevel);
    print " + computed max component file '".$outlabelfilename."'...\n" if ( $verbose );
   }
   push(@outfiles,$outlabelfilename);
  }
  # compute max component file
  my $mpmmaxfilename = $infilename;
  $mpmmaxfilename =~ s/\.nii\.gz/\_cleaned\.nii\.gz/;
  if ( ! -e $mpmmaxfilename || $overwrite || fileIsNewer($infilename,$mpmmaxfilename) ) {
   my $infilenames = join("\,",@outfiles);
   ssystem("hitOverlay -in $infilenames -out $mpmmaxfilename -o ADD -f",$debuglevel);
   ssystem("fslcpgeom $infilename $mpmmaxfilename",$debuglevel);
   print " + created clean mpm file '$mpmmaxfilename'.\n" if ( $verbose );
  }
  # >>> >>> >>>
  my $mpmcleanmaxfilename = $mpmmaxfilename;
  $mpmcleanmaxfilename =~ s/\.nii\.gz/\_filledholes\.nii\.gz/;
  if ( ! -e $mpmcleanmaxfilename || $overwrite || fileIsNewer($mpmmaxfilename,$mpmcleanmaxfilename) ) {
   # get misclassified holes
   my $diffimage = $infilename;
   $diffimage =~ s/\.nii\.gz/\_diff\.nii\.gz/;
   ssystem("hitOverlay -src1 $infilename -src2 $mpmmaxfilename -out $diffimage -o IOR -value 0 -f",$debuglevel);
   print " + created difference volume file '".$diffimage."'.\n" if ( $verbose );
   # get background holes
   my $bgholesfilename = $infilename;
   $bgholesfilename =~ s/\.nii\.gz/\_bgholes\.nii\.gz/;
   my $tmpblackholesfile = $tmp."_blackholes_".basename($mpmmaxfilename);
   ssystem("itkLabelVolume -i $mpmmaxfilename -o $tmpblackholesfile -n -r",$debuglevel);
   ssystem("hitThreshold -i $tmpblackholesfile -o $bgholesfilename -r 1 -f",$debuglevel);
   unlink($tmpblackholesfile) if ( -e $tmpblackholesfile );
   my $nonzerobgpixels = `hitHistogram -i $bgholesfilename -count`;
   if ( int($nonzerobgpixels)>0 ) {
    ssystem("hitOverlay -src1 $diffimage -src2 $bgholesfilename -out $diffimage -o OR -f",$debuglevel);
    print " + created diff overlay data set.\n" if ( $verbose );
    exit(1);
   }
   unlink($bgholesfilename) if ( -e $bgholesfilename );
   # count holes
   my $result = `hitHistogram -i $diffimage -count`;
   my @elements = split(" ",$result);
   if ( int($elements[0])>0 ) {
    $result = `itkLabelVolume -i $diffimage --count`;
    my @elements2 = split(" ",$result);
    my $nholes = $elements2[-1];
    print "  + found ".$nholes." holes...\n" if ( $verbose );
    my $difflabelfile = $diffimage;
    $difflabelfile =~ s/\.nii\.gz/\_lables\.nii\.gz/;
    # convert to uchar before further processing (not necessary any more)
    #my $tmpfilename = $tmp."_".$difflabelfile;
    #ssystem("itkLabelVolume -i $diffimage -o $tmpfilename --ignoreless 1 --verbose",$debuglevel);
    #ssystem("hitConverter -in $tmpfilename -out $difflabelfile -r DIRECT -out:format UCHAR -f -verbose -low 0",$debuglevel);
    #unlink($tmpfilename) if ( -e $tmpfilename );
    ssystem("itkLabelVolume -i $diffimage -o $difflabelfile --ignoreless 1 --verbose",$debuglevel);
    print "   + created label file '".$difflabelfile."'.\n" if ( $verbose );
    my @fillholefilenames = ();
    for ( my $k=1 ; $k<=$nholes ; $k++ ) {
     # get separated file for every hole
     my $difflevelfilename = $difflabelfile;
     my $kstr = sprintf("%02d",$k);
     $difflevelfilename =~ s/\.nii\.gz/\_value$kstr\.nii\.gz/;
     ssystem("hitThreshold -f -i $difflabelfile -g $k -o $difflevelfilename -verbose",$debuglevel);
     print "   + created filtered label component file '$difflevelfilename'.\n" if ( $verbose );
     # median filter
     my $mdifflevelfilename = $difflevelfilename;
     $mdifflevelfilename =~ s/\.nii\.gz/\_median\.nii\.gz/;
     # ssystem("itkMedianFilter3d -i $difflevelfilename -o $mdifflevelfilename --radius 2 --verbose",$debuglevel);
     ssystem("hitFilter -i $difflevelfilename -o $mdifflevelfilename -f DILATE -native",$debuglevel);
     print "   + created dilated file '".$mdifflevelfilename."'.\n" if ( $verbose );
     # masking and histogram value
     my $tmpfilename = $tmp."_".basename($mdifflevelfilename);
     ssystem("hitOverlay -src1 $mpmmaxfilename -src2 $mdifflevelfilename -out $tmpfilename -o MASK -f",$debuglevel);
     my $result2 = `hitHistogram -i $tmpfilename -nonzero:list -stdout`;
     unlink($tmpfilename) if ( -e $tmpfilename );
     my @elements3 = split("\n",$result2);
     print "result2=".$elements3[1]."\n" if ( $verbose );
     # set new data value
     my $fillholefilename = $difflevelfilename;
     $fillholefilename =~ s/\.nii\.gz/\_filled\.nii\.gz/;
     ssystem("hitThreshold -i $difflevelfilename -o $fillholefilename -b $elements3[1] -f",$debuglevel);
     push(@fillholefilenames,$fillholefilename);
     print "   + created colored hole filed file '".$fillholefilename."'.\n" if ( $verbose );
     # cleaning
     unlink($difflevelfilename) if ( -e $difflevelfilename );
     unlink($mdifflevelfilename) if ( -e $mdifflevelfilename );
    }
    # create corrected clean file
    my $infilledfilenames = $mpmmaxfilename.",";
    $infilledfilenames .= join("\,",@fillholefilenames);
    ssystem("hitOverlay -in $infilledfilenames -out $mpmcleanmaxfilename -o ADD -f",$debuglevel);
    ssystem("fslcpgeom $infilename $mpmcleanmaxfilename",$debuglevel);
    print " + created final clean mpm file '".$mpmcleanmaxfilename."'.\n" if ( $verbose );
    # create separated area files
    my $basefilename = $mpmcleanmaxfilename;
    my $lowThreshold  = $nonzeros[1];
    my $highThreshold = $nonzeros[-1];
    ssystem("hitThreshold -i $mpmcleanmaxfilename -o $basefilename -noneempty -save:all -l $lowThreshold -h $highThreshold -f",$debuglevel);
    # cleaning
    unlink(@fillholefilenames) if ( scalar(@fillholefilenames)>0 );
    unlink($difflabelfile) if ( -e $difflabelfile );
   }
   unlink($diffimage) if ( -e $diffimage );
  }
 ### >>>
}

### >>>
sub setFileMD5Checksum {
 my ($infilename,$outfilename,$verbose,$debug) = @_;
 my $checksum = `md5 $infilename`;
 chomp($checksum);
 my @names = split(/=/,$checksum);
 $names[1] =~ s/^\s+|\s+$//g;
 $outfilename =~ s/.nii.gz/_${names[1]}.nii.gz/;
 ### ERROR: Rename is not possible if data are going to external drive (Cross-device link error)
 ## rename($infilename,$outfilename) || printfatalerror "FATAL ERROR: Cannot rename file '".$infilename."': $!";
 copy($infilename,$outfilename) || printfatalerror "FATAL ERROR: Cannot copy file '".$infilename."': $!";
 unlink($infilename) if ( -e $infilename );
 return $outfilename;
}

### >>>
sub getProjectStructureIdent {
 my ($dbh,$tbPrjLabel,$verbose,$debug) = @_;
 my @names = split(/\_/,$tbPrjLabel);
 my $prjDBIdent = fetchFromAtlasDatabase($dbh,"SELECT id FROM atlas.projects WHERE name='$names[0]'");
 if ( $prjDBIdent>0 ) {
  return fetchFromAtlasDatabase($dbh,"SELECT id FROM atlas.structures WHERE name='$names[1]' AND projectId='$prjDBIdent'");
 }
 return 0;
}

### >>>
sub shiftLabelKeys {
 my ($dataIndices_ptr,$datasize_ptr,$ndatasize_ptr,$shiftValues_ptr,$verbose,$debug) = @_;
 my %dataIndices = %{$dataIndices_ptr};
 my @datasize = @{$datasize_ptr};
 my $xysize = $datasize[0]*$datasize[1];
 my @ndatasize = @{$ndatasize_ptr};
 my $nxysize = $ndatasize[0]*$ndatasize[1];
 my @shiftValues = @{$shiftValues_ptr};
 my %outIndices = ();
 while ( my ($key,$value)=each(%dataIndices) ) {
  my $z = floor($key/$xysize);
  my $y = floor(($key-$z*$xysize)/$datasize[0]);
  my $x = $key-($z*$xysize+$y*$datasize[0]);
  my $nkey = ($x+$shiftValues[0])+($y+$shiftValues[1])*$ndatasize[0]+($z+$shiftValues[2])*$nxysize;
  $outIndices{$nkey} = $value;
 }
 return %outIndices;
}

### csf([1:85 110:end],:,:) = 0;
sub punchFilter {
 my ($dataIndices_ptr,$datasize_ptr,$values_ptr,$verbose,$debug) = @_;
 my %dataIndices = %{$dataIndices_ptr};
 my @filtervalues = @{$values_ptr};
 my @datasize = @{$datasize_ptr};
 print "punchFilter(): datasize=(".join(",",@datasize)."), filtervalues=(".join(",",@filtervalues).")\n" if ( $verbose );
 my @xfiltervalues = ();
 foreach my $filtervalue (@filtervalues) {
  my @values = split(/:/,$filtervalue);
  ## print " xfiltervalue=".join(",",@values)."\n";
  foreach my $value (@values) {
   $value = $datasize[0] if ( $value =~ m/end/ );
   push(@xfiltervalues,$value);
  }
 }
 my $nxfiltervalues = scalar(@xfiltervalues);
 print " + xfiltervalues=".join(",",@xfiltervalues)."\n" if ( $verbose );
 my %outIndices = ();
 my $n = 0;
 my $xysize = $datasize[0]*$datasize[1];
 while ( my ($key,$value)=each(%dataIndices) ) {
  my $z = floor($key/$xysize);
  my $y = floor(($key-$z*$xysize)/$datasize[0]);
  ### >>>
  my $x = $key-($z*$xysize+$y*$datasize[0]);
  my $isInRange = 0;
  for ( my $i=0 ; $i<$nxfiltervalues ; $i+=2 ) {
   if ( $x>=($xfiltervalues[$i]-1) && $x<=($xfiltervalues[$i+1]-1) ) {
    $isInRange = 1;
   }
  }
  if ( !$isInRange ) {
   my $xyz = $x+$y*$datasize[0]+$z*$xysize;
   print "  + value[".$key."]=".$value." -> xyz=(".$x.":".$y.":".$z.") -> $xyz\n" if ( $n<10 );
   $n += 1;
   $outIndices{$key} = $value;
  }
 }
 return %outIndices;
}

### >>>
sub lowpassMaskFilter {
 my ($dataIndices_ptr,$maskIndices_ptr,$threshold,$verbose,$debug) = @_;
 my %dataIndices = %{$dataIndices_ptr};
 my %maskIndices = %{$maskIndices_ptr};
 my %filteredIndices = ();
 while ( my ($key,$value)=each(%dataIndices) ) {
  if ( exists($maskIndices{$key}) ) {
   if ( $maskIndices{$key}<$threshold ) {
    $filteredIndices{$key} = $value;
   }
  } else {
   $filteredIndices{$key} = $value;
  }
 }
 return %filteredIndices;
}

### >>>
my $ontologypath = $ENV{HOME}."/Projects/Atlas/projects/ontology/data/tables";
printfatalerror "FATAL ERROR: Invalid ontology path '".$ontologypath."': $!" unless ( -d $ontologypath );

### parameters
my $help = 0;
my $log = 0;
my $history = 0;
my $verbose = 0;
my $overwrite = 0;
my $legend = 0;
my $watermark = 0;
my $debug = 0;
my $echo = 0;
my $surfmpm = 0;
my $surfout = 0;
my $volume = 0;
my $render = 0;
my $float = 0;
my $nifti = 0;
my $freesurfer = 0;
my $maxcluster = 0;
my $fillholes = 0;
my $width = 400;
my $height = 400;
my $showcross = 0;
my $showgrid = 0;
my $rerender = 0;
my $update = 0;
my $pedantic = 0;
my $standard = 0;
my $niter = 0;
my $normalized = 0;
my $gnormalized = 0;
my $uniquecolor = 0;
my $inflated = 0;
my $smoothwm = 0;
my $toolbox = 0;
my $atlas = 0;
my $threshold = 0.3;
my $colorcodefile = "";
my $projectnames = undef;
my $onlyidentstr = "";
my $csidestring = "l,r";
my $refBrain = "Colin27";
my $method = "iptools";
my $surfmodel = "freesurfer";
my @sides = ("top","left","front","bottom","right","back");
my $watermarktext = "Preliminary Results";
my $hostname = "localhost";
my $accessfile = "login.dat";
my $versionstring = undef;
my $ontologyfile = undef;
my $outfilename = undef;
my $projectoutpath = undef;
my $projectpath = undef;
my $datapath = undef;
my @argvlist = ();

###
sub createTabImage {
 my ($picoutfiles_ref_ptr,$picFile,$surftype,$side,$nprojects,$numAreas,$atlasname,$atlasDataCorePath) = @_;
 my @picoutfiles = @{$picoutfiles_ref_ptr};
 my $tabout = $picFile."_tab.png";
 unlink($tabout) if ( -e $tabout );
 ssystem("montage @picoutfiles -tile 3x2 -geometry +0+0 $tabout",$debug);
 my $tmpAtlasFile = $picFile."_tmpfile.png";
 if ( $watermark ) {
  print " watermarking output image...\n" if ( $verbose );
  ### watermarking image
  my $watermarkout = $tabout;
  $watermarkout =~ s/\.png/\_watermarked.png/i;
  my $wopts = "-size 240x160 xc:none -fill grey";
  $wopts .= " -gravity NorthWest -draw \"text 35,35 \'$watermarktext\'\"";
  $wopts .= " -gravity SouthEast -draw \"text 25,25 \'$watermarktext\'\"";
  $wopts .= " miff:- | composite -tile -";
  ssystem("convert $wopts $tabout $watermarkout",$debug);
  copy($watermarkout,$tmpAtlasFile) || printfatalerror "FATAL ERROR: Could not copy: $!";
 } else {
  copy($tabout,$tmpAtlasFile) || printfatalerror "FATAL ERROR: Cannot copy: $!";
 }
 my $finalout = createOutputPath("$atlasDataCorePath/pics");
 $nprojects = $numAreas;
 $finalout .= "/${atlasname}_${side}_N${nprojects}_nlin2Std${refBrain}_${surftype}_mpmsurf.png";
 if ( -e $canvas ) {
  ssystem("composite -gravity center $tmpAtlasFile $canvas $finalout",$debug);
  unlink($tmpAtlasFile);
 } else {
  printwarning "WARNING: No canvas template file '".$canvas."' available." unless ( -e $canvas );
  move($tmpAtlasFile,$finalout) || printfatalerror "FATAL ERROR: Cannot move file: $!";
 }
 return $finalout;
}

### only regular data area allowed (no combinations)
sub isValidMPMArea {
 my ($projectstructures_ptr,$area) = @_;
 my @projectstructures = @{$projectstructures_ptr};
 foreach my $structure (@projectstructures) {
  next if ( $structure =~ m/\_l$/ );
  $structure =~ s/\_r$//;
  return 1 if ( $area =~ m/^${structure}_/ );
 }
 return 0;
}

### gapmap indices are >=500
sub getMPMIndexValues {
 my ($mpmdatatable_ptr,$threshold,$verbose,$debug) = @_;
 my %mpmdatatable = %{$mpmdatatable_ptr};
 ### >>>
  my %indexvalues = ();
  my %wthresholds = ();
  my @aMPMThresholds = ();
  my %datatable = %{$mpmdatatable{"data"}};
  while ( my ($key,$value)=each(%datatable) ) {
   my @datavalues = @{$value};
   my $ndatavalues = scalar(@datavalues);
   ### handle gapmap data
   my $tPValue = 0.0;
   my $haveGMapValues = 0;
   for ( my $i=0 ; $i<$ndatavalues ; $i+=2 ) {
    $tPValue += $datavalues[$i+1] if ( $datavalues[$i]<500 );
    $haveGMapValues = 1 if ( $datavalues[$i]>499 );
   }
   my @datavalues2 = ();
   if ( $haveGMapValues ) {
    if ( $tPValue<1.0 ) {
     for ( my $i=0 ; $i<$ndatavalues ; $i+=2 ) {
      if ( $datavalues[$i]>499 ) {
       push(@datavalues2,$datavalues[$i]);
       push(@datavalues2,1.0-$tPValue);
      } else {
       push(@datavalues2,$datavalues[$i]);
       push(@datavalues2,$datavalues[$i+1]);
      }
     }
    } elsif ( $tPValue>1.0 ) {
     for ( my $i=0 ; $i<$ndatavalues ; $i+=2 ) {
      if ( $datavalues[$i]<500 ) {
       push(@datavalues2,$datavalues[$i]);
       push(@datavalues2,$datavalues[$i+1]);
      }
     }
    }
   } else {
    @datavalues2 = @datavalues;
   }
   ### get max pvalue
   my $maxPValue = 0.0;
   my $maxId = -1;
   for ( my $i=0 ; $i<$ndatavalues ; $i+=2 ) {
    if ( $datavalues2[$i+1]>$maxPValue ) {
     $maxPValue = $datavalues2[$i+1];
     $maxId = $datavalues2[$i];
    }
    if ( $maxId>0 ) {
     @{$wthresholds{$maxId}} = () unless ( exists($wthresholds{$maxId}) );
     push(@{$wthresholds{$maxId}},$maxPValue);
     if ( $maxPValue>=$threshold ) {
      $indexvalues{$key} = $maxId;
     }
    }
   }
  }
  while ( my ($key,$value)=each(%wthresholds) ) {
   my @pvalues = @{$value};
   my $npvalues = scalar(@pvalues);
   my $mth = 0.0;
   if ( $npvalues>0 ) {
    for ( my $i=0 ; $i<$npvalues ; $i++ ) {
     $mth += $pvalues[$i];
    }
    $mth = $mth/$npvalues;
   }
   print "id=$key, thresholds[n=".$npvalues."]=$mth\n" if ( $debug );
   push(@aMPMThresholds,$mth);
  }
  my $mth = 0.0;
  my $nMPMThresholds = scalar(@aMPMThresholds);
  if ( $nMPMThresholds>0 ) {
   for ( my $i=0 ; $i<$nMPMThresholds ; $i++ ) {
    $mth += $aMPMThresholds[$i];
   }
   $mth = $mth/$nMPMThresholds;
  }
  print " + got ".scalar(keys(%indexvalues))." non-zero mpm indices, mean MPMThreshold[n=".$nMPMThresholds."]=".$mth.".\n" if ( $verbose );
 ### >>>
 return %indexvalues;
}

sub saveMPMDataSetAs {
 my ($indexvalues_ptr,$labelnames_ptr,$outfilename,$sidename,$verbose,$debug) = @_;
 my %indexvalues = %{$indexvalues_ptr};
 my %labelnames = %{$labelnames_ptr};
 ### >>>
  my $volopts = "-in:size "; ## size only true for colin27
  $volopts .= ($refBrain =~ m/colin/i)?"256 256 256":"229 193 193";
  $volopts .= " -out:compress true";
  my $mpmOutFilename = $outfilename;
  # my $indexfilename = $tmp."_mpmtable_gnormalized_".$sidename.".itxt";
  my $indexfilename = $mpmOutFilename;
  $indexfilename =~ s/.nii.gz/.itxt/;
  my $tmpoutfilename = $indexfilename;
  $tmpoutfilename =~ s/\.itxt$/\.vff\.gz/;
  print "DEBUG: Indexfilename=$indexfilename, tmpfilename=$tmpoutfilename, mpmoutfilename=$mpmOutFilename\n" if ( $debug );
  saveINormalizedValuesAs(\%indexvalues,$indexfilename,$verbose,$debug);
  saveXMLLabelInfoFile(\%indexvalues,\%labelnames,$indexfilename,$verbose,$debug);
  my %com = (
    "command" => "hitConverter",
    "options" => "-f $volopts -in:format uint8 -out:world no",
    "input"   => "-in ".$indexfilename,
    "output"  => "-out ".$tmpoutfilename
  );
  hsystem(\%com,1,$debug);
  ssystem("hitConverter -in $tmpoutfilename -nifti -out:mniworld",$debug);
  $tmpoutfilename =~ s/.vff.gz/.nii.gz/;
  if ( !($refBrain =~ /colin/i) ) {
   ssystem("hitSetHeader -in $tmpoutfilename -f -origin -97 -97 -115",$debug);
  }
  # createFilledHolesDataset($outvolumefile,$side,$verbose,$debug) if ( $fillholes );
  $mpmOutFilename = setFileMD5Checksum($tmpoutfilename,$mpmOutFilename,$verbose,$debug);
  print " + Saved mpm file '".$mpmOutFilename.".\n" if ( $verbose );
 ### >>>
}

### >>>
sub printusage {
 my $errortext = shift;
 if ( defined($errortext) ) {
  print color('red');
  print "error:\n ".$errortext.".\n";
  print color('reset');
 }
 print "usage:\n ".basename($0)." [--help|?][(-d|--debug)][(-m|--marker)][--pedantic][(-u|--update)][(-v|--verbose)][--standard][(-l|--log)][--toolbox]\n";
 print "\t[(-w|--watermark)][(-o|--overwrite)][(-f|--float)][(-g|--grid)][(-r|--render)][--nifti][--model <name=$surfmodel>][--atlas]\n";
 print "\t[(-i|--iterations) <value=$niter>][(-c|--colorcodes) <filename>][(-t|--threshold) <value=$threshold>][--unique][--echo][--smoothwm]\n";
 print "\t[--side (l|r|b=$csidestring)][--volume][--method <name=$method>][--legend][--surfout][--inflate][--reference <name=$refBrain>]\n";
 print "\t[--(g)normalized][--history][--freesurfer][--maxcluster][--fillholes][--projectoutpath <name>][--projectpath <name>][--only <list-of-ids>]\n";
 print "\t[--atlaspath <name>][--out <filename>] (--volume|--surface) ((--path <pathname>) || (-p|--project) <filename|name1,name2,...>)\n";
 print "parameter:\n";
 print " version.................... ".getScriptRepositoryVersion($0,$debug)."\n";
 print " atlas path................. '".$ATLASPATH."'\n";
 print " project path............... <projectpath=atlaspath>/projects/contourrecon/data\n";
 print " ontology path.............. '".$ontologypath."'\n";
 print " date string................ ".getDateString()."\n";
 print " last call.................. '".getLastProgramLogMessage($0)."'\n";
 exit(1);
}

if ( @ARGV>0 ) {
 foreach my $argnum (0..$#ARGV) {
  push(@argvlist,$ARGV[$argnum]);
 }
 GetOptions(
  'help|?+' => \$help,
  'log|l+' => \$log,
  'echo+' => \$echo,
  'history+' => \$history,
  'verbose|v+' => \$verbose,
  'update|u+' => \$update,
  'debug|d+' => \$debug,
  'legend+' => \$legend,
  'maxcluster+' => \$maxcluster,
  'surfout+' => \$surfout,
  'watermark|w+' => \$watermark,
  'render|r+' => \$render,
  'volume+' => \$volume,
  'surface+' => \$surfmpm,
  'freesurfer+' => \$freesurfer,
  'unique+' => \$uniquecolor,
  'overwrite|o+' => \$overwrite,
  'normalized+' => \$normalized,
  'gnormalized+' => \$gnormalized,
  'pedantic+' => \$pedantic,
  'standard+' => \$standard,
  'toolbox+' => \$toolbox,
  'atlas+' => \$atlas,
  'iterations|i=i' => \$niter,
  'fillholes+' => \$fillholes,
  'grid|g+' => \$showgrid,
  'float|f+' => \$float,
  'nifti+' => \$nifti,
  'inflate+' => \$inflated,
  'smoothwm+' => \$smoothwm,
  'default-mac+' => \$standard,
  'version=s' => \$versionstring,
  'side=s' => \$csidestring,
  'threshold|t=s' => \$threshold,
  'colorcodes|c=s' => \$colorcodefile,
  'reference=s' => \$refBrain,
  'method=s' => \$method,
  'only=s' => \$onlyidentstr,
  'ontology=s' => \$ontologyfile,
  'model=s' => \$surfmodel,
  'projectpath=s' => \$projectpath,
  'projectoutpath=s' => \$projectoutpath,
  'out=s' => \$outfilename,
  'atlaspath=s' => \$ATLASPATH,
  'path=s' => \$datapath,
  'project|p=s' => \$projectnames) ||
 printusage();
}
printProgramLog($0,1) if $history;
printusage() if $help;
printusage("Missing required options") if ( !defined($projectnames) && !defined($datapath) );
$volume = 1 if ( $toolbox );
printusage("No modality. Use surfmpm or volume") if ( $surfmpm==0 && $volume==0 );

### checking executables
my @executables = ("hitConverter","hitOverlay","hitFilter","hitHistogram","hitThreshold","hitInfo","hitMeshMaxProbability",
                      "hitRenderToImage","itkLabelVolume");
my $nfails = checkExecutables($verbose,@executables);
printusage("Missing ".$nfails." required executables. See https://github.com/JulichBrainAtlas/ContourRecon for details") if ( $nfails>0 );

### connect to database
my $accessfilename = $DATABASEPATH."/scripts/data/".$accessfile;
my @accessdata = getAtlasDatabaseAccessData($accessfilename);
printfatalerror "FATAL ERROR: Malfunction in 'getAtlasDatabaseAccessData($accessfilename)'." if ( @accessdata!=2 );
my $dbh = connectToDatabase($hostname,$accessdata[0],$accessdata[1],"jubrain");

### >>>
createProgramLog($0,\@argvlist);

### >>>
if ( $standard ) {
 $colorcodefile = "data/areacolors.txt";
 $verbose = 1;
 $float = 1;
 $inflated = 1;
 $smoothwm = 1;
 $gnormalized = 1;
 $maxcluster = 1;
 $legend = 1;
 $render = 1;
 $niter = 15;
 $nifti = 1;
 $ATLASPATH = getAtlasContourDataDrive()."/Projects/Atlas";
}
$normalized += 1 if ( $gnormalized );

### >>>
my %sidenames = (
  "l" => "left",
  "r" => "right",
  "b" => "both"
);

### >>>
if ( $atlas ) {
 print "Creating atlas mpm dataset from internal JulichBrain pipeline data table...\n" if ( $verbose );
 ## loading ontology file to get id/official name relation
  my $ontologyfilename = $ontologypath."/".$ontologyfile;
  printfatalerror "FATAL ERROR: Cannot open ontology file '".$ontologyfilename."': $!" unless ( -e $ontologyfilename );
  print " + loading ontology file '".$ontologyfilename."'...\n" if ( $verbose );
  my %structureHBPNames = ();
  my %csvdata = loadCSVFile($ontologyfilename,$verbose,$debug);
  my @datalines = @{$csvdata{"data"}};
  foreach my $dataline (@datalines) {
   my @elements = split(/\;/,$dataline);
   # my $psname = $elements[8];
   # $psname .= "_".$elements[9];
   my $psname = $elements[16];
   my $hbpname = $elements[19];
   $hbpname =~ s/^\s+|\s+$//g;
   my $id = getProjectStructureIdent($dbh,$psname,$verbose,$debug);
   print " > $psname => id=$id >>> $hbpname\n" if ( $debug );
   $structureHBPNames{$id} = $hbpname;
  }
  $structureHBPNames{"500"} = "Frontal-I (GapMap)";
  $structureHBPNames{"501"} = "Frontal-II (GapMap)";
  $structureHBPNames{"502"} = "Frontal-to-Temporal (GapMap)";
  $structureHBPNames{"503"} = "Temporal-to-Parietal (GapMap)";
  $structureHBPNames{"504"} = "Frontal-to-Occipital (GapMap)";
 ## processing
 my $mpmoutfilename = "";
 my $threshold = 0.2;
 if ( $projectnames =~ m/^atlas$/ ) {
  my @sidenames = ("left","right");
  foreach my $sidename (@sidenames) {
   my $tablename = "data/mpm/to".$refBrain."F/".lc($refBrain)."_fgpmaps_datatable_orig_".$sidename.".dat";
   if ( -e $tablename ) {
    print " + loading MPM datatable '".$tablename."', filetime=".getTimeStamp($tablename)." ...\n" if ( $verbose );
    my %mpmdatatable = loadMPMDataTable($tablename,$verbose,$debug);
    my %indexValues = getMPMIndexValues(\%mpmdatatable,$threshold,$verbose,$debug);
    if ( !defined($outfilename) ) {
     $mpmoutfilename = $ATLASPATH."/projects/contourrecon/data/atlas/vol/mpm/";
     printfatalerror "FATAL ERROR: Invalid output path '".$outfilename."'. Use option --out to specify name of the output file." unless ( -d $mpmoutfilename );
     $mpmoutfilename .= "JuBrain_MPMAtlas_".lc($refBrain)."_".$sidename.".nii.gz";
    } else {
     $mpmoutfilename = $outfilename
    }
    saveMPMDataSetAs(\%indexValues,\%structureHBPNames,$mpmoutfilename,$sidename,$verbose,$debug);
   } else {
    printwarning "WARNING: Cannot find table file '".$tablename."': $!\n";
   }
  }
 } else {
  printfatalerror "FATAL ERROR: Name for the output volume file required!" unless ( defined($outfilename) );
  if ( -e $projectnames ) {
   my $sidename = (basename($projectnames)=~m/_left/)?"left":"right";
   print " + loading local MPM datatable '".$projectnames."', side=$sidename, filetime=".getTimeStamp($projectnames)." ...\n" if ( $verbose );
   my %mpmdatatable = loadMPMDataTable($projectnames,$verbose,$debug);
   if ( length($onlyidentstr)>0 ) {
    my @valididents = split(/\,/,$onlyidentstr);
    my @dropidents = ();
    my @fileinfos = @{$mpmdatatable{"files"}};
    foreach my $fileinfo (@fileinfos) {
     my @elements = split(/\;/,$fileinfo);
     my $id = $elements[0];
     push(@dropidents,$id) if ( !isInArray($id,\@valididents) );
    }
    print "  + dropping ".scalar(@dropidents)." areas: (".join("\,",@dropidents).")\n" if ( $verbose );
    %mpmdatatable = dropIndexValuesFromMPMDataTable(\%mpmdatatable,\@dropidents,$verbose,$debug);
   }
   my %indexValues = getMPMIndexValues(\%mpmdatatable,$threshold,$verbose,$debug);
   saveMPMDataSetAs(\%indexValues,\%structureHBPNames,$outfilename,$sidename,$verbose,$debug);
  } else {
   printfatalerror "FATAL ERROR: Cannot find table file '".$projectnames."': $!";
  }
 }
 $dbh->disconnect();
 exit(1);
} elsif ( defined($datapath) ) { ### !!!!! HBP specific processing !!!!!
 print "Creating local ".$sidenames{$csidestring}." mpm volumes for files in '".$datapath."'...\n" if ( $verbose );
 my $ontologyfilename = $ontologypath."/".$ontologyfile;
 print " + Loading ontology file '".$ontologyfilename."'...\n" if ( $verbose );
 my %prjNames = ();
 my %csvdata = loadCSVFile($ontologyfilename,$verbose,$debug);
 my @datalines = @{$csvdata{"data"}};
 foreach my $dataline (@datalines) {
  my @elements = split(/\;/,$dataline);
  my $nelements = scalar(@elements);
  if ( $nelements==20 ) {
   if ( length($elements[7])>0 ) { ## is for combi
    $prjNames{$elements[17]} = $elements[8]."_".$elements[7];
   } else {
    $prjNames{$elements[17]} = $elements[8]."_".$elements[9];
   }
  } else {
   printwarning "Malformated dataline '".$dataline."'.\n";
  }
 }
 if ( $toolbox ) {
  ### *****************************************************************************************************
  ### Consult Simon's mpm toolbox to create mpm dataset based on 'CreateNewPMap.m'
  ### *****************************************************************************************************
 } else {
  ### using my code to create mpm dataset
  my %mpmdatatable = ();
  my $tablename = "./data/mpm/local/creatempm_".getDateString();
  my $outtablename = $tablename."_".$csidestring;
  $outtablename .= "_".$versionstring if ( defined($versionstring) );
  $outtablename .= ".dat";
  if ( ! -e $outtablename || $overwrite ) {
   print " + Parsing input data path '".$datapath."'...\n" if ( $verbose );
   $mpmdatatable{"name"} = $sidenames{$csidestring}." datatable of data in '".$datapath."'";
   my @infilenames = getDirent($datapath);
   foreach my $infilename (@infilenames) {
    next unless ( $infilename =~ /\.nii\.gz/ );
    next unless ( $infilename =~ /_${csidestring}_/ );
    my @elements = split(/\_/,$infilename);
    my $tbLabel = $elements[0]."_".$elements[1];
    if ( exists($prjNames{$tbLabel}) ) {
     my @names = split(/\_/,$prjNames{$tbLabel});
     my $prjDBIdent = fetchFromAtlasDatabase($dbh,"SELECT id FROM atlas.projects WHERE name='$names[0]'");
     if ( $prjDBIdent>0 ) {
      my $ident = fetchFromAtlasDatabase($dbh,"SELECT id FROM atlas.structures WHERE name='$names[1]' AND projectId='$prjDBIdent'");
      print "  + processing file '".$infilename."', tbLabel=".$tbLabel." -> internal=".$prjNames{$tbLabel}." -> dbIdent=".$ident."...\n" if ( $verbose );
      my $fullfilename = $datapath."/".$infilename;
      print "   > fullfilename='".$fullfilename."'.\n" if ( $verbose );
      ### >>>
      my $vfffilename = $fullfilename;
      $vfffilename =~ s/.nii.gz/.vff.gz/;
      ssystem("hitConverter -i $fullfilename -vff",$debug);
      my $indexfile = $tmp."__project_".$names[0]."__structure_".$names[1]."_".$csidestring.".itxt";
      ssystem("hitConverter -f -in $vfffilename -out $indexfile -out:compress false",$debug);
      %mpmdatatable = addStructureValuesFromIndexFileToMPMDataTable(\%mpmdatatable,$indexfile,$ident,$verbose,$debug) unless ( $debug );
      unlink($indexfile) if ( -e $indexfile );
      ### >>>
     } else {
      printwarning "WARNING: Invalid project '$names[0]': tbLabel=$tbLabel.\n";
     }
    } else {
     printwarning "WARNING: Invalid label name $tbLabel.\n";
    }
   }
   saveMPMDataTable(\%mpmdatatable,$outtablename,$verbose,$debug);
   print "  + saved local mpm datatable '".$outtablename."'.\n" if ( $verbose );
  } else {
   print " + Loading mpm data table '".$outtablename."'...\n" if ( $verbose );
   %mpmdatatable = loadMPMDataTable($outtablename,$verbose,$debug);
  }
  ### >>>
  my $threshold = 0.3;
  my %indexvalues = ();
  my %wthresholds = ();
  my @aMPMThresholds = ();
  my %datatable = %{$mpmdatatable{"data"}};
  while ( my ($key,$value)=each(%datatable) ) {
   my @datavalues = @{$value};
   my $maxPValue = 0.0;
   my $maxId = -1;
   for ( my $i=0 ; $i<scalar(@datavalues) ; $i+=2 ) {
    if ( $datavalues[$i+1]>$maxPValue ) {
     $maxPValue = $datavalues[$i+1];
     $maxId = $datavalues[$i];
    }
    if ( $maxId>0 ) {
     @{$wthresholds{$maxId}} = () unless ( exists($wthresholds{$maxId}) );
     push(@{$wthresholds{$maxId}},$maxPValue);
     if ( $maxPValue>=$threshold ) {
      $indexvalues{$key} = $maxId;
     }
    }
   }
   ## print " >>> key=$key => datavalues=(".join(",",@datavalues).") > max[".$maxId."]=".$maxPValue."\n";
  }
  while ( my ($key,$value)=each(%wthresholds) ) {
   my @pvalues = @{$value};
   my $npvalues = scalar(@pvalues);
   my $mth = 0.0;
   if ( $npvalues>0 ) {
    for ( my $i=0 ; $i<$npvalues ; $i++ ) {
     $mth += $pvalues[$i];
    }
    $mth = $mth/$npvalues;
   }
   print "id=$key, thresholds[n=".$npvalues."]=$mth\n";
   push(@aMPMThresholds,$mth);
  }
  my $mth = 0.0;
  my $nMPMThresholds = scalar(@aMPMThresholds);
  if ( $nMPMThresholds>0 ) {
   for ( my $i=0 ; $i<$nMPMThresholds ; $i++ ) {
    $mth += $aMPMThresholds[$i];
   }
   $mth = $mth/$nMPMThresholds;
  }
  print " + Got ".scalar(keys(%indexvalues))." non-zero mpm indices, MPMThreshold[n=".$nMPMThresholds."]=".$mth.".\n" if ( $verbose );
  ### save mpm dataset
  my $volopts = "-in:size "; ## size only true for colin27
  $volopts .= ($refBrain =~ m/colin/i)?"256 256 256":"229 193 193";
  $volopts .= " -out:compress true";
  my $mpmOutFilename = $outfilename;
  my $indexfilename = $tmp."_mpmtable_gnormalized_".$csidestring.".itxt";
  my $tmpoutfilename = $indexfilename;
  $tmpoutfilename =~ s/.itxt/.vff.gz/;
  saveIValuesAs(\%indexvalues,$indexfilename,$verbose,$debug);
  my %com = (
    "command" => "hitConverter",
    "options" => "-f $volopts -in:format uint16 -out:world no",
    "input"   => "-in ".$indexfilename,
    "output"  => "-out ".$tmpoutfilename
  );
  hsystem(\%com,1,$debug);
  ssystem("hitConverter -in $tmpoutfilename -nifti -out:mniworld",$debug);
  $tmpoutfilename =~ s/.vff.gz/.nii.gz/;
  if ( !($refBrain =~ /colin/i) ) {
   ssystem("hitSetHeader -in $tmpoutfilename -f -origin -97 -97 -115",$debug);
  }
  # createFilledHolesDataset($outvolumefile,$side,$verbose,$debug) if ( $fillholes );
  $mpmOutFilename = setFileMD5Checksum($tmpoutfilename,$mpmOutFilename,$verbose,$debug);
  print " + Saved mpm file '".$mpmOutFilename.".\n" if ( $verbose );
 }
 my $starfilename = $outfilename;
 $starfilename =~ s/\.nii\.gz//;
 my $mpmSrcFilename = `ls $starfilename*`;
 chomp($mpmSrcFilename);
 my $mpmOutFilename = $mpmSrcFilename;
 $mpmOutFilename =~ s/\.nii\.gz/\_public\.nii\.gz/;
 print " + Computing public mpm file '".$mpmOutFilename."'...\n" if ( $verbose );
 my $rValues = "248,249,244,245,246,247,333,332,335,334,329,329,331,331,331,331,331,331,331,330,330,330,330,330,265,265,269,269,268,267,268,267,28,34,242,243,261,261,201,209,210,195,197,193,200,196,199,198,204,102,101,100,103,216,217";
 ssystem("hitThreshold -in $mpmSrcFilename -out $mpmOutFilename -r $rValues -f",$debug);
 ###
 exit(1);
}

### >>>
my $lContourReconPath = defined($projectpath)?$projectpath:$ATLASPATH;
$lContourReconPath .= "/projects/contourrecon/data";
printfatalerror "FATAL ERROR: Invalid contour recon path '".$lContourReconPath."': $!" unless ( -d $lContourReconPath );
my $atlasDataCorePath = $lContourReconPath."/atlas";
if ( ! -d $atlasDataCorePath ) {
 printwarning "WARNING: Invalid core atlas project path '".$atlasDataCorePath."'.\n";
 exit(1) if $pedantic;
}

###
my $ref = "to".$refBrain;
$ref .= "F" if $float;
$ref .= "g" if $gnormalized;

### get projects
my @projects = getAtlasProjects($projectnames);
my $nprojects = scalar(@projects);

### ---
my @projectstructures; ## = getContourProjectStructures("$lContourReconPath/$projects[0]");
my @csides = split(/\,/,$csidestring);
my $ncsides = @csides;
if ( $volume ) {
 print "Create local mpm volumes for ".scalar(@projects)." atlas projects...\n" if ( $verbose );
 ### setup
 my $volopts = "-in:size 256 256 256 -out:compress true";
 $volopts .= " -v" if ( $verbose );
 my @colormap = getDefaultColormap(256,0,$verbose,$debug);
 print " + created default colormap with ".scalar(@colormap)." entries.\n" if ( $verbose );
 ### loading datatables
 print " loading mpm datatables...\n" if ( $verbose );
 my %refbraininfo = getReferenceBrainName($refBrain);
 my $tablename = "./data/mpm/to".$refbraininfo{"name"}."F/".$refbraininfo{"short"}."_fgpmaps_datatable_orig";
 my %tablenames = ();
 $tablenames{"l"} = $tablename."_left.dat";
 $tablenames{"r"} = $tablename."_right.dat";
 my %mpmdatatables = ();
 %{$mpmdatatables{"l"}} = loadMPMDataTable($tablenames{"l"},$verbose,$debug);
 %{$mpmdatatables{"r"}} = loadMPMDataTable($tablenames{"r"},$verbose,$debug);
 ### >>>
 foreach my $project (@projects) {
  my $prjDBIdent = fetchFromAtlasDatabase($dbh,"SELECT id FROM atlas.projects WHERE name='$project'");
  print " + processing project '".$project."', id=".$prjDBIdent."...\n" if ( $verbose );
  # get processed structures (with combinations)
  my $projectpath = $lContourReconPath."/".$project;
  @projectstructures = getContourProjectStructures($projectpath);
  my %combistructures = getContourProjectCombinations($projectpath);
  my @removestrucs = ();
  while ( my ($key,$value)=each(%combistructures) ) {
   push(@removestrucs,split(/\ /,$value));
   push(@projectstructures,$key);
  }
  @projectstructures = removeFromArray(\@projectstructures,\@removestrucs,$verbose,$debug);
  ### get project colors
  print "  + loading colors of project in '".$projectpath."'...\n" if ( $verbose );
  my %projectcolors = getContourProjectColors($projectpath,$verbose);
  if ( $debug ) {
   while ( my ($key,$value) = each(%projectcolors) ) {
    my @colors = @{$value};
    print "  + structureId=$key, color=(".join(":",@colors).")\n";
   }
  }
  ### <<<
  my %structureNameIds = ();
  my @projectstructureIdents = ();
  foreach my $structure (@projectstructures) {
   my $side  = substr($structure,-1);
   my $structurename = substr($structure,0,-2);
   my @defs = fetchRowFromAtlasDatabase($dbh,"SELECT id,type FROM atlas.structures WHERE name='$structurename' AND projectId='$prjDBIdent'");
   my ($ident,$type) = ($defs[0],$defs[1]);
   push(@projectstructureIdents,$ident);
   $structureNameIds{$ident} = $structurename;
   print "  + structure '".$structure."', id=".$ident.", type=".$type.", side=".$side."...\n" if ( $verbose );
   ### extract maximum area fro each area from mpm datatable >>>
  }
  ### get used project ids and shift them to values beyond the highest value in the colin dataset (which is 222)
  ### update project colormap for mpm volume file
  print "  + shifting structure colors and updating colormap...\n" if ( $verbose );
  my @ncolormap = @colormap;
  @projectstructureIdents = removeDoubleEntriesFromArray(@projectstructureIdents);
  my %shifttable = ();
  my $shiftColorId = 225;
  foreach my $structureIdent (@projectstructureIdents) {
   $shifttable{$structureIdent} = $shiftColorId;
   if ( exists($structureNameIds{$structureIdent}) ) {
    my $structurename = $structureNameIds{$structureIdent};
    if ( exists($projectcolors{$structurename}) ) {
     my @color = @{$projectcolors{$structurename}};
     print "   + convert color of structureName=".$structurename." to rgb=(".join(':',@color).")...\n" if ( $verbose );
     my $ncp = 3*$shiftColorId;
     $ncolormap[$ncp+0] = $color[0];
     $ncolormap[$ncp+1] = $color[1];
     $ncolormap[$ncp+2] = $color[2];
    } elsif ( exists($projectcolors{$structureIdent}) ) {
     my @color = @{$projectcolors{$structureIdent}};
     print "   + convert color of structureId=".$structureIdent." to rgb=(".join(':',@color).")...\n" if ( $verbose );
     my $ncp = 3*$shiftColorId;
     $ncolormap[$ncp+0] = $color[0];
     $ncolormap[$ncp+1] = $color[1];
     $ncolormap[$ncp+2] = $color[2];
    } else {
     warn "WARNING: Cannot find any color conversion value structure (name=$structurename, id=$structureIdent).\n";
    }
   } else {
    printfatalerror "FATAL ERROR: StructureId/StructureName mismatch.";
   }
   $shiftColorId += 1;
  }
  ### create and save mpm value of the complete project
  my $projectmpmpath = createOutputPath($projectpath."/to".$refBrain."Fg/".$method."/mpm/data");
  print " > $projectmpmpath\n" if ( $debug );
  foreach my $side ("l","r") {
   ## fetching data
   my %indexvalues = getProjectMPMFromMPMDataTable(\%{$mpmdatatables{$side}},\@projectstructureIdents,$threshold,$verbose,$debug);
   %indexvalues = getShiftedIndexValues(\%indexvalues,\%shifttable,$verbose,$debug);
   print " + got ".scalar(keys(%indexvalues))." non-zero index values.\n" if ( $verbose );
   my $indexfilename = $projectmpmpath."/".$project."_mpmtable_gnormalized_".$sidenames{$side}.".itxt";
   saveIValuesAs(\%indexvalues,$indexfilename,$verbose,$debug);
   print "  + saved index table file '".$indexfilename."'.\n" if ( $verbose );
   ## save mpm volume file
   my $outvolumefile = $indexfilename;
   $outvolumefile =~ s/\.itxt/\.vff\.gz/;
   my %com = (
    "command" => "hitConverter",
    "options" => "-f $volopts -in:format uchar -out:world no",
    "input"   => "-in $indexfilename",
    "output"  => "-out $outvolumefile"
   );
   hsystem(\%com,1,$debug);
   $outvolumefile = createNiftiFile($outvolumefile,$overwrite,$verbose,$debug) if ( $nifti || $fillholes );
   createFilledHolesDataset($outvolumefile,$side,$verbose,$debug) if ( $fillholes );
  }
  ## save misc data
   my $misccorefilename = $projectmpmpath."/".$project."_mpmtable_gnormalized";
   my $infofilename = $misccorefilename.".info";
   open(FPout,">$infofilename") || printfatalerror "FATAL ERROR: Cannot create info file '".$infofilename."': $!";
    while ( my ($key,$value) = each(%shifttable) ) {
     my $structurename = fetchFromAtlasDatabase($dbh,"SELECT name FROM atlas.structures WHERE id='$key'");
     print FPout $project."_".$structurename." ".$key." ".$value."\n";
    }
   close(FPout);
   print "  + saved info file '".$infofilename."'.\n" if ( $verbose );
   ## create and save lut colormap
   my $colormapfilename = $misccorefilename.".lut";
   saveLutColormap($colormapfilename,\@ncolormap,$verbose,$debug);
   if ( $verbose ) {
    print "  + saved colormap file '".$colormapfilename."'.\n";
    print "   + HINT: To be usable in mricron copy the file to '/Applications/mricron/mricron.app/Contents/MacOS/lut'!\n";
   }
 }
}

if ( $surfmpm ) {
  my $refBrainLC = lc($refBrain);
  my $refBrainPath = $ATLASPATH."/data/brains/human/reference/".$refBrain;
  $refBrainPath = "./data" if ( -d "./data/surf/freesurfer" );
  printfatalerror "FATAL ERROR: Invalid path '".$refBrainPath."' for reference surface files: $!" unless ( -d $refBrainPath );
  my $refBrainSurfPath = $refBrainPath."/surf/".$refBrainLC;
  my %refBrainMeshFiles = ();
  my %refBrainInflatedMeshFiles = ();
  my %refBrainSmoothwmMeshFiles = ();
  print " refBrainSurfPath=".$refBrainSurfPath."\n";
  if ( $surfmodel eq "freesurfer" ) {
   $refBrainMeshFiles{"b"} = "$refBrainSurfPath/${refBrainLC}T1_both_optimized_WM_normalized.off";
   $refBrainMeshFiles{"l"} = "$refBrainSurfPath/freesurfer/rh_pial_affine.off";
   $refBrainMeshFiles{"r"} = "$refBrainSurfPath/freesurfer/lh_pial_affine.off";
   $refBrainInflatedMeshFiles{"l"} = "$refBrainSurfPath/freesurfer/rh_inflated.off";
   $refBrainInflatedMeshFiles{"r"} = "$refBrainSurfPath/freesurfer/lh_inflated.off";
   $refBrainSmoothwmMeshFiles{"l"} = "$refBrainSurfPath/freesurfer/rh_smoothwm_affine.off";
   $refBrainSmoothwmMeshFiles{"r"} = "$refBrainSurfPath/freesurfer/lh_smoothwm_affine.off";
  } elsif ( $surfmodel eq "surfrelax" ) {
   $refBrainMeshFiles{"b"} = "$refBrainSurfPath/${refBrainLC}T1_both_optimized_WM_normalized.off";
   $refBrainMeshFiles{"l"} = "$refBrainSurfPath/${refBrainLC}T1_left_optimized_WM_normalized.off";
   $refBrainMeshFiles{"r"} = "$refBrainSurfPath/${refBrainLC}T1_right_optimized_WM_normalized.off";
  } else {
   printfatalerror "FATAL ERROR: Invalid surface model '".$surfmodel."'.";
  }
  while ( my ($key,$refBrainMeshFile)=each(%refBrainMeshFiles) ) {
   printfatalerror "FATAL ERROR: Cannot find reference brain mesh dataset '".$refBrainMeshFile."'." unless ( -e $refBrainMeshFile );
  }
  ### colin values
  my %colinvalues = ();
  if ( $freesurfer ) {
   my @values1 = loadFreeSurferASCCurvFile("./data/surf/freesurfer/orig/lh.thickness.asc",$verbose);
   my $nvalues1 = @values1;
   @{$colinvalues{$nvalues1}} = @values1;
   my @values2 = loadFreeSurferASCCurvFile("./data/surf/freesurfer/orig/rh.thickness.asc",$verbose);
   my $nvalues2 = @values2;
   @{$colinvalues{$nvalues2}} = @values2;
   print "> nverts[surf1]=$nvalues1, nverts[surf2]=$nvalues2\n" if ( $verbose );
  }
  ### creating a surface based mpm dataset
  my $atlasname = $projects[0];
  if ( defined($projectoutpath) ) {
   $atlasname = $projectoutpath;
   $atlasDataCorePath = $lContourReconPath."/atlas/surfmpm/$projectoutpath";
  } else {
   $atlasDataCorePath = $lContourReconPath."/".$atlasname;
  }
  my $atlasDataPath = $atlasDataCorePath."/".$ref."/".$method."/atlas";
  my $plabelpath = createOutputPath($atlasDataPath."/3d/label");
  my $surfoutpath = createOutputPath($atlasDataPath."/3d/surf");
  printfatalerror "FATAL ERROR: Invalid number of sides." if ( $ncsides==0 );
  foreach my $cside (@csides) {
   next if ( $cside=="b" || $cside=="l" || $cside=="r" );
   printfatalerror "FATAL ERROR: Invalid side specifier '$cside': $!";
  }
  ### processing
  foreach my $cside (@csides) {
   my $numAreas = 0;
   my $plabelfile = "$plabelpath/surfatlas_${cside}.plabel";
   print "creating atlas file '".$plabelfile."'...\n" if ( $verbose );
   open(DAT,">$plabelfile") || printfatalerror "FATAL ERROR: Could not create atlas file '".$plabelfile."': $!";
   print DAT "# surface atlas plabel file\n";
   foreach my $project (@projects) {
    print " processing project '$project'...\n" if ( $verbose );
    my @projectstructures = getContourProjectStructures($lContourReconPath."/".$project);
    print DAT "# project: ".$project."\n";
    print DAT "# structures: @projectstructures\n";
    my $prjpath = $lContourReconPath."/".$project."/".$ref."/".$method."/pmap/vol";
    if ( $normalized==1 ) {
     $prjpath .= "/normalized";
    } elsif ( $normalized==2 ) {
     $prjpath .= "/gnormalized";
    } else {
     $prjpath .= "/orig";
    }
    my @areas = getAreaDirs($prjpath,"nlin2Std${refBrainLC}",$cside,\@projectstructures);
    my $nareas = @areas;
    if ( $nareas==0 ) {
      warn "Could not find any valid areas in '".$prjpath."'!\n";
      exit(1) if ( $pedantic );
    } else {
      foreach my $area (@areas) {
       ## print "  area file '$area'...\n" if ( $verbose );
       my $datainpath = "$prjpath/$area/3d/$surfmodel/label";
       if ( ! -d $datainpath ) {
        print "WARNING: Could not find '".$datainpath."'. skipping!\n";
        exit(1) if ( $pedantic );
        next;
       }
       my $hasFile = 0;
       my @files = getDirent($datainpath);
       foreach my $file (@files) {
        if ( $file =~ m/\_edit\.dat$/i ) {
         print "  adding label file '".$file."'...\n" if ( $verbose );
         print DAT "$datainpath/$file\n";
         $numAreas++;
         $hasFile = 1;
         last;
        }
       }
       unless ( $hasFile ) {
        foreach my $file (@files) {
         next unless ( $file =~ m/${refBrainLC}.dat$/i );
         print "  adding label file '".$file."'...\n" if ( $verbose );
         print DAT "$datainpath/$file\n";
         $numAreas++;
         last;
        }
       }
      }
    }
    # print ">>> created '$plabelfile'.\n";
   }
   close(DAT);
   ### create max probability map on the surface
   my $outFile = $atlasDataPath."/3d/label/surfatlas_".$cside."_mpm.dat";
   my $xmlFile = $outFile;
   $xmlFile =~ s/\.dat/\.xml/i;
   if ( ! -e $outFile || $overwrite ) {
     my $opts = "-threshold $threshold";
     $opts .= " -verbose" if ( $verbose );
     if ( $niter>0 ) {
       $opts .= " -filter:iter $niter -filter:method mean";
       $opts .= " -mesh $refBrainMeshFiles{$cside}";
     }
     if ( $colorcodefile ) {
      die "FATAL ERROR: Could not find color code file '".$colorcodefile."'." unless ( -e $colorcodefile );
      $opts .= " -colorcodes $colorcodefile";
     }
     ssystem("hitMeshMaxProbability $opts -in $plabelfile -out $outFile -xml $xmlFile",$debug);
     print "Created '".$outFile."' and '".$xmlFile."'.\n" if $verbose;
   }
   ### convert into freesurfer format
   if ( $freesurfer ) {
    my @datalines = ();
    open(FPin,"<$outFile") || printfatalerror "FATAL ERROR: Cannot open '".$outFile."' for reading: $!";
     while ( <FPin> ) {
      chomp($_);
      push(@datalines,$_);
     }
    close(FPin);
    my $nlines = @datalines;
    my $strucascfile = $outFile;
    $strucascfile =~ s/\.dat/\.asc/;
    open(FPout,">$strucascfile") || printfatalerror "FATAL ERROR: Cannot create '".$strucascfile."': $!";
     my @vertexcoords = @{$colinvalues{$nlines}};
     for ( my $i=0 ; $i<$nlines ; $i++ ) {
      print FPout "$vertexcoords[$i] $datalines[$i]\n";
     }
    close(FPout);
   }
   ### creating colormap ...
   my $colFile = createOutputPath($atlasDataPath."/3d/colormap");
   $colFile .= "/surfatlas_".$cside."_mpm.vcol";
   my $cmapinfofile = xml2colorfile($xmlFile,$outFile,$colFile,$uniquecolor);
   ## clustering ...
   if ( $maxcluster && $cside ne "b" ) {
    print "maximum clustering ...\n" if $verbose;
    # print "DEBUG: labelfile: '$outFile'\n";
    # print "DEBUG: meshfile:  '$refBrainMeshFiles{$cside}'\n";
    my $nColorFile = clusterLabelData($outFile,$refBrainMeshFiles{$cside},$colFile,$verbose,$debug);
    print "created color file '".$nColorFile."' for maximum cluster.\n" if $verbose;
    $colFile = $nColorFile;
   }
   ### create output surface in coff format
   # savecofffile($surfoutpath,$refBrainMeshFiles{$cside},$colFile,$project) if ( $surfout );  
   ### render ...
   if ( $render ) {
    print "render data...\n" if $verbose;
    my $picFile = createOutputPath("$atlasDataPath/3d/pics");
    $picFile .= "/surfatlas_${cside}_mpm";
    my $opts = "--width $width --height $height";
    my $sidestring = join("\,",@sides);
    $opts .= " --view $sidestring";
    $opts .= " --overlay rgba:$colFile --mirror";
    ssystem("hitRenderToImage $opts -i $refBrainMeshFiles{$cside} -o $picFile",$debug);
    my @picoutfiles = ();
    foreach my $side (@sides) {
      push(@picoutfiles,"${picFile}_${side}.png");
    }
    my @finalouts = ();
    push(@finalouts,createTabImage(\@picoutfiles,$picFile,"gm",$cside,$nprojects,$numAreas,$atlasname,$atlasDataCorePath));
    # render smoothwm ...
    if ( $smoothwm && $cside ne "b" ) {
     my $npicFile = $picFile."_smoothwm";
     print " render inflated '".$npicFile."' ...\n" if $verbose;
     ssystem("hitRenderToImage $opts -i $refBrainSmoothwmMeshFiles{$cside} -o $npicFile",$debug);
     my @npicoutfiles = ();
     foreach my $side (@sides) {
      push(@npicoutfiles,"${npicFile}_${side}.png");
     }
     push(@finalouts,createTabImage(\@npicoutfiles,$npicFile,"smoothwm",$cside,$nprojects,$numAreas,$atlasname,$atlasDataCorePath));
    }
    # render inflated
    if ( $inflated && $cside ne "b" ) {
     my $npicFile = "${picFile}_inflated";
     print " render inflated '".$npicFile."' ...\n" if $verbose;
     ssystem("hitRenderToImage $opts -i $refBrainInflatedMeshFiles{$cside} -o $npicFile",$debug);
     my @npicoutfiles = ();
     foreach my $side (@sides) {
      push(@npicoutfiles,"${npicFile}_${side}.png");
     }
     push(@finalouts,createTabImage(\@npicoutfiles,$npicFile,"inflated",$cside,$nprojects,$numAreas,$atlasname,$atlasDataCorePath));
    }
    if ( $legend ) {
      print " creating legend color pics '".$cmapinfofile."' ...\n" if ( $verbose );
      my @legendfiles = ();
      open(FP,"<$cmapinfofile") || printfatalerror "FATAL ERROR: Could not open colormap info file '".$cmapinfofile."': $!";
      while ( <FP> ) {
       chomp($_);
       my @elements = split(/\ /,$_);
       next if ( @elements!=4 );
       my $outfile = createOutputPath("$atlasDataPath/3d/pics/areas");
       $outfile .= "/mpmcolor_".$elements[0].".png";
       my $red = $elements[1];
       my $green = $elements[2];
       my $blue = $elements[3];
       my $label = "-gravity center -stroke black -strokewidth 2 -annotate 0 $elements[0]";
       $label .= " -stroke none -fill white -annotate 0 $elements[0]";
       ssystem("convert -size 80x20 xc:\"rgb($red,$green,$blue)\" $label $outfile",$debug);
       push(@legendfiles,$outfile);
      }
      close(FP);
      my $nfiles = @legendfiles;
      my $tilestring = ($nfiles<40)?"1x$nfiles":"x40";
      my $legendfile = $atlasDataPath."/3d/pics/areas/legend.png";
      my $opts = "-background #000000 -geometry +1+1";
      ssystem("montage $opts @legendfiles -tile $tilestring $legendfile",$debug);
      foreach my $finalout (@finalouts) {
       my $tmpfile = $finalout;
       $tmpfile =~ s/\.png/\_legend.png/i;
       ssystem("composite -geometry +1376+13 $legendfile $finalout $tmpfile",$debug);
       unlink($finalout);
       move($tmpfile,$finalout) || printfatalerror "FATAL ERROR: cannot move file: $!";
      }
    }
   }
  }
}
