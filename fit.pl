#!/usr/bin/perl
use strict;
use warnings;
use feature qw(say);

set_autopthread_targ(2);
set_autopthread_size(0);

use blib '/home/dima/projects/PDL-FFTW3';

use PDL;
use PDL::IO::GD;
use PDL::Graphics::Gnuplot;
use PDL::NiceSlice;
use PDL::OpenCV qw(Smooth Sobel Remap %cvdef);
use PDL::LinearAlgebra;
use PDL::Complex;
use PDL::FFTW3;
use PDL::Image2D;
use PDL::IO::Storable;
use Storable qw(store retrieve);
use Getopt::Euclid;


my $cache;
my %image;
my @cache_stage2;
if( defined $ARGV{'--cache'} )
{
  say STDERR "Reading cache";

  $cache = retrieve $ARGV{'--cache'};

  %image        = %{ $cache->{image} };
  @cache_stage2 = @{ $cache->{stage2} } if defined $cache->{stage2} && !$ARGV{'--only1'};
}



if( !%image )
{
  my ($img_remapped, $pano) = readImages();

  for my $name_img ( ['img',  $img_remapped],
                     ['pano', $pano ] )
  {
    my ($name, $img) = @$name_img;

    my $gradx = $img->copy;
    my $grady = $img->copy;

    my $img_smoothed = $img->zeros;

    Smooth( $img, $img_smoothed, $cvdef{CV_GAUSSIAN},
            $ARGV{'--smoothradius'},
            $ARGV{'--smoothradius'}, 0, 0 );
    $img_smoothed /= 3*3;

    $image{$name}{orig}     = $img;
    $image{$name}{smoothed} = $img_smoothed;
    $image{$name}{size}     = [$img->dims];
    pop $image{$name}{size};

    # edges looking at each channel separately
    $image{$name}{edgecomponents}{x} = $gradx;
    $image{$name}{edgecomponents}{y} = $grady;

    Sobel( $img_smoothed, $gradx, 1, 0, $cvdef{CV_SCHARR} );
    Sobel( $img_smoothed, $grady, 0, 1, $cvdef{CV_SCHARR} );

    # I now join the channel-independent edges into single-channel edge vectors. I
    # do this by computing the most-aligned direction, weighted by the magnitude
    # of each vector. The magnitude of the result is simply the mean magnitude of
    # the sources

    # the gradients have dimensions (x,y,rgb)
    my $V = cat($gradx, $grady)->mv(3,0); # dims (grad, x,y,rgb )

    my $M = outer( $V, $V );      # dims (M0, M1, x, y, rgb)
    $M = $M->mv(-1,0)->sumover;   # dims (M0, M1, x, y)
    my ($l, $v) = msymeigen( $M, 0, 1 );
    $v = $v((1),:,:,:);           # select the larger eigenvalue
    my $m = sqrt(inner( $V, $V) )->mv(-1,0)->sumover; # sum of the lengths of the gradient vectors

    # Done. I have the normalized directions ($v) and the magnitudes ($m). I now
    # construct the output array of vectors
    $image{$name}{edges} = $v * $m->dummy(0);


    # I want to align the vectors mod pi. I treat these as complex numbers.Given two
    # complex numbers,
    #
    # Re(a*conj(b)) = |a||b| cos( th_a - th_b ). This shows angle differences mod
    # 2pi. To show differences mod pi, I simply double the angles by squaring the
    # numbers: Re( a^2 * conj(b^2) ) = |a|^2 |b|^ cos( 2* (th_a - th_b) )

    # I square each of the vectors
    $image{$name}{edges} = cplx $image{$name}{edges};
    $image{$name}{edges} = $image{$name}{edges} * $image{$name}{edges};
  }
}


my ($dx,$dy, @mounted_size);
if( !@cache_stage2 )
{
  # and correlate
  ($dx,$dy, @mounted_size) = correlate_conj( $image{pano}{edges},
                                             $image{img} {edges} );
}
else
{
  ($dx,$dy, @mounted_size) = @cache_stage2;
}

store { image  => \%image,
        stage2 => [$dx,$dy, @mounted_size] }, "cache";



# plot the aligned images
my $img0_gray = real $image{img} {orig}->mv(-1,0)->average;
my $img1_gray = real $image{pano}{orig}->mv(-1,0)->average;


my @mounted = map { $_->range( [0,0], \@mounted_size, 'e') } ( $img0_gray, $img1_gray );

my @w;
if($ARGV{'--plot'} eq 'alignpair')
{
  $mounted[1] = $mounted[1]->range( [$dx,$dy], [$mounted[1]->dims], 'p' );
  for my $i (0..1)
  {
    my $x = $mounted[$i];
    push @w, gpwin;
    $w[-1]->plot( globalwith => 'image',
                  square => 1,
                  extracmds => 'set yrange [*:*] reverse',
                  $x->(0:1000,0:400) );
  }
  sleep(1000);
  exit;
}
if($ARGV{'--plot'} eq 'regions')
{
  my @mounted = mount_images( $image{img}{edges}, $image{pano}{edges} );
  $mounted[1] = $mounted[1]->range( [0,$dx,$dy], [$mounted[1]->dims], 'p' );

  $mounted[0] = cplx $mounted[0];
  $mounted[1] = cplx $mounted[1];

  my $p = real( $mounted[0] * Cconj $mounted[1] );
  say "This should match the reported corr: value: " . sum( $p((0),:,:) );

  gplot( globalwith => 'image',
         square => 1,
         extracmds => 'set yrange [*:*] reverse',
         $p((0),:,:));
  sleep(1000);
  exit;
}






sub readImages
{
  my $pi         = 3.14159265359;
  my @sensorsize = ( 7.31, 5.49 );
  my $focal      = 5.1;


  my $img  = PDL::IO::GD->new( $ARGV{'--photo'} )->to_pdl->float / 255.0;
  my $pano = PDL::IO::GD->new( $ARGV{'--pano'}  )->to_pdl->float / 255.0;
  my $px_per_rad = $pano->dim(0) / (2.0 * $pi);

  my @fov        = map { list atan( $_ / 2.0 / $focal ) * 2.0 } @sensorsize;
  my @remap_size = map { $_ * $px_per_rad } @fov;

  my $img_remapped = float zeros( @remap_size, 3 );

  my $mapx = float (tan( $img_remapped->xlinvals(-0.5, 0.5)->float * $fov[0] ) * $focal / $sensorsize[0] + 0.5 ) * ($img->dim(0)-1);
  my $mapy = float (tan( $img_remapped->ylinvals(-0.5, 0.5)->float * $fov[1] ) * $focal / $sensorsize[1] + 0.5 ) * ($img->dim(1)-1);

  Remap( $img,
         $img_remapped,
         $mapx, $mapy,
         1 + 9,                 # CV_INTER_LINEAR+CV_WARP_FILL_OUTLIERS
         zeros(4)->float );

  return ($img_remapped, $pano);
}

# computes the peak of the correlation of img0 and conj(img1)
sub correlate_conj
{
  my @imgs = @_;
  return correlate_conj_mounted( mount_images(@imgs) );



  # computes the peak of the correlation of img0 and conj(img1). img0 and img1
  # are guaranteed to be 0-padded and identically-dimensioned
  sub correlate_conj_mounted
  {
    my @mounted = @_;

    my $Npoints = $mounted[0]->dim(1) * $mounted[0]->dim(2);

    my @fft = dog cplx fft2 real cat @mounted;
    my $corr = cplx ifft2( real( $fft[0] * Cconj( $fft[1] )) ) / $Npoints;


    my ($corr_max, @corr_offset ) = max2d_ind( $corr->re );

    say "best offset: @corr_offset; corr: $corr_max";

    # correlation plot
    if( $ARGV{'--plot'} eq 'corr' )
    {
      gplot( globalwith => 'image',
             square => 1,
             extracmds => 'set yrange [*:*] reverse',
             re $corr
           );
      sleep 1000;
      exit;
    }

    my @mounted_size = $mounted[0]->dims;
    shift @mounted_size;
    return (@corr_offset, @mounted_size);
  }
}

sub mount_images
{
  my @imgs = @_;

  # mount the images into larger, equal matrix
  my $sizes = pdl( [$imgs[0]->dims], [$imgs[1]->dims] );
  my @mountsize = PDL::list( $sizes->transpose->maximum->(1:-1) * 2 );

  my @mounted;
  foreach my $img(@imgs)
  {
    # mount the image
    my $mountedimg = cplx zeros( 2, @mountsize );
    $mountedimg->(:, 0:$img->dim(1)-1, 0:$img->dim(2)-1 ) .= $img;
    push @mounted, $mountedimg;
  }

  return @mounted;
}

__END__

=head1 NAME

fit - prototype for the image aligner

=head1 REQUIRED ARGUMENTS

=over

=item --pano <pano>

Panorama render image

=for Euclid:
  pano.type: readable

=item --photo <photo>

Photo being annotated

=for Euclid:
  photo.type: readable

=back

=head1 OPTIONS

=over

=item --cache <file>

File to read cached data from

=for Euclid:
    file.type:        readable

=item --only1

Read only the first stage of the cache

=item --plot <what>

Selects what should be plotted at the end. Could be C<corr> for the correlation
map, C<alignpair> to show the aligned original pair of images or C<regions> to
show which regions of the image aligned the best in the best-case alignment

=for Euclid:
    what.type: /corr|alignpair|regions/
    what.default: ''

=item --s[moothradius] <smoothradius>

The radius of the initial smoothing filter. The default is smoothradius.default.
This must be an odd integer >= 3

=for Euclid:
    smoothradius.type:       int, smoothradius >= 3 && smoothradius % 2 == 1
    smoothradius.type.error: smoothradius must be odd integer >= 3
    smoothradius.default:    7


=item --help

Print the usual program information

=back

=head1 AUTHOR

Dima Kogan, C<< <dima@secretsauce.net> >>

=head1 COPYRIGHT

Copyright (c) 2013, Dima Kogan

This module is free software. It may be used, redistributed and/or modified
under the terms of the GNU public license or the Perl Artistic License
