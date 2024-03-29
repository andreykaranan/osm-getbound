#!/usr/bin/perl

# ABSTRACT: save osm boundary to .poly file

# $Id$


use 5.010;
use strict;
use warnings;
use utf8;
use autodie;

use lib 'lib';

use Carp;
use Log::Any qw/$log/;
use Log::Any::Adapter 0.11 ('Stderr');

use FindBin qw{ $Bin };

use Getopt::Long;
use List::Util qw{ min max sum };
use List::MoreUtils qw{ first_index none notall };
use File::Slurp;

use YAML;

use Math::Polygon;
use Math::Polygon::Tree 0.061 qw/ :all /;

use App::OsmGetbound::OsmData;
use App::OsmGetbound::OsmApiClient;
use App::OsmGetbound::RelAlias;


####    Settings

my %api_opt = (
    api => $ENV{GETBOUND_API} || 'osm',
);

our %WRITER = (
    poly => 'App::OsmGetbound::WriterPoly',
    shp  => 'App::OsmGetbound::WriterShp',
);



####    Command-line

my $writer_name;
GetOptions (
    'api=s'     => \$api_opt{api},
    'file=s'    => \my $filename,
    'o=s'       => \my $outfile,
    'onering!'  => \my $onering,
    'noinner!'  => \my $noinner,
    'proxy=s'   => \$api_opt{proxy},
    'aliases=s' => \my $alias_config,
    'writer=s'  => \$writer_name,
    'om=s'      => sub { my $m = $_[1]; my $w = $WRITER{$m}; croak "Unknown mode: $m" if !$w; $writer_name = $w; },
    'offset|buffer=f' => \my $offset,
) or die "Invalid options";

if ( !@ARGV ) {
    print "Usage:  getbound.pl [options] <relation> [<relation> ...]\n\n";
    print "relation - id or alias\n\n";
    print "Available options:\n";
    print "     -api <api>      - api to use (@{[ sort keys %App::OsmGetbound::OsmApiClient::API ]})\n";
    print "     -o <file>       - output filename (default: STDOUT)\n";
    print "     -proxy <host>   - use proxy\n";
    print "     -onering        - merge rings\n\n";
    exit 1;
}


####    Writer

$writer_name ||= $WRITER{poly};
eval "require $writer_name; 1" or die $@;
my $writer = $writer_name->new();


####    Aliases
my $alias = App::OsmGetbound::RelAlias->new($alias_config);


####    Process

my @rel_ids = map { my $al = $alias->get_id($_); ref $al ? @$al : ($al) } @ARGV;
croak "Unknown alias"  if notall {defined} @rel_ids;

my %valid_role = (
    ''          => 'outer',
    'outer'     => 'outer',
    'border'    => 'outer',
    'exclave'   => 'outer',
    'inner'     => 'inner',
    'enclave'   => 'inner',
);


# getting and parsing
my $osm = App::OsmGetbound::OsmData->new();
if ( $filename ) {
    $log->notice( "Reading file $filename" );
    my $xml = read_file $filename;
    $osm->load($xml);
}
else {
    my $api = App::OsmGetbound::OsmApiClient->new(%api_opt);
    for my $id ( @rel_ids ) {
        $log->notice("Downloading relation ID=$id");
        my $xml = $api->get_object( relation => $id, 'full' );
        $osm->load($_)  for @{ ref $xml ? $xml : [$xml] };
    }
}


# connecting rings: outers are counterclockwise!
$log->notice( "Creating polygons" );

# contours are arrays [ \@chain, $is_inner ]
my @contours;

for my $rel_id ( @rel_ids ) {
    my $relation = $osm->{relations}->{$rel_id};
    my %ring;

    for my $member ( @{ $relation->{member} } ) {
        next unless $member->{type} eq 'way';
        my $role = $valid_role{ $member->{role} }  or next;
    
        my $way_id = $member->{ref};
        if ( !exists $osm->{chains}->{$way_id} ) {
            $log->warn( "Incomplete data: way $way_id is missing" );
            next;
        }

        push @{ $ring{$role} },  [ @{ $osm->{chains}->{$way_id} } ];
    }

    while ( my ( $type, $list_ref ) = each %ring ) {
        while ( @$list_ref ) {
            my @chain = @{ shift @$list_ref };
        
            if ( $chain[0] eq $chain[-1] ) {
                my @contour = map { $osm->{nodes}->{$_} } @chain;
                my $order = 0 + Math::Polygon::Calc::polygon_is_clockwise(@contour);
                state $desired_order = { outer => 0, inner => 1 };
                push @contours, [
                    $order == $desired_order->{$type} ? \@contour : [reverse @contour],
                    $type ~~ 'inner',
                ];
                next;
            }

            my $pos = first_index { $chain[0] eq $_->[0] } @$list_ref;
            if ( $pos > -1 ) {
                shift @chain;
                $list_ref->[$pos] = [ (reverse @chain), @{$list_ref->[$pos]} ];
                next;
            }
            $pos = first_index { $chain[0] eq $_->[-1] } @$list_ref;
            if ( $pos > -1 ) {
                shift @chain;
                $list_ref->[$pos] = [ @{$list_ref->[$pos]}, @chain ];
                next;
            }
            $pos = first_index { $chain[-1] eq $_->[0] } @$list_ref;
            if ( $pos > -1 ) {
                pop @chain;
                $list_ref->[$pos] = [ @chain, @{$list_ref->[$pos]} ];
                next;
            }
            $pos = first_index { $chain[-1] eq $_->[-1] } @$list_ref;
            if ( $pos > -1 ) {
                pop @chain;
                $list_ref->[$pos] = [ @{$list_ref->[$pos]}, reverse @chain ];
                next;
            }
            $log->error( "Invalid data: ring is not closed" );

            $log->debug( "Non-connecting chain:\n" . Dump( \@chain ) );
            exit 1;
        }
    }
}


if ( !@contours || none { !$_->[1] } @contours ) {
    $log->error( "Invalid data: no outer rings" );
    exit 1;
}


# outers first
# todo: second sort by area
@contours = sort { $a->[1] <=> $b->[1] || $#{$b->[0]} <=> $#{$a->[0]} } @contours;


##  Offset
if ( defined $offset ) {
    require Math::Clipper;

    $log->notice( "Calculating buffer" );
    my $ofs_contours = Math::Clipper::offset( [ map { $_->[0] } @contours ], $offset, 1000/$offset );

    @contours =
        sort { $a->[1] <=> $b->[1] || $#{$b->[0]} <=> $#{$a->[0]} }
        map {[ $_, Math::Polygon::Calc::polygon_is_clockwise(@$_) ]}
        map {[@$_, $_->[0]]}
        @$ofs_contours;
}



##  Merge rings
if ( $onering ) {
    $log->notice( "Merging rings" );

    my $first_item = shift @contours;
    my @ring = @{ $first_item->[0] };

    while ( @contours ) {
        my ($add_contour, $is_inner) = @{ shift @contours };
        next if $noinner && $is_inner;

        # find close[st] points
        my $ring_center = polygon_centroid( \@ring );

        if ( $is_inner ) {
            my ( $index_i, $dist ) = ( 0, metric( $ring_center, $ring[0] ) );
            for my $i ( 1 .. $#ring ) {
                my $tdist = metric( $ring_center, $ring[$i] );
                next if $tdist >= $dist;
                ( $index_i, $dist ) = ( $i, $tdist );
            }
            $ring_center = $ring[$index_i];
        }

        @contours = sort { 
                    metric( $ring_center, polygon_centroid($a->[0]) ) <=>
                    metric( $ring_center, polygon_centroid($b->[0]) )
                } @contours;

        my $add_center = polygon_centroid( $add_contour );

        my ( $index_r, $dist ) = ( 0, metric( $add_center, $ring[0] ) );
        for my $i ( 1 .. $#ring ) {
            my $tdist = metric( $add_center, $ring[$i] );
            next if $tdist >= $dist;
            ( $index_r, $dist ) = ( $i, $tdist );
        }

        ( my $index_a, $dist ) = ( 0, metric( $ring[$index_r], $add_contour->[0] ) );
        for my $i ( 1 .. $#$add_contour ) {
            my $tdist = metric( $ring[$index_r], $add_contour->[$i] );
            next if $tdist >= $dist;
            ( $index_a, $dist ) = ( $i, $tdist );
        }

        # merge
        splice @ring, $index_r, 0, (
            $ring[$index_r],
            @$add_contour[ $index_a .. $#$add_contour-1 ],
            @$add_contour[ 0 .. $index_a-1 ],
            $add_contour->[$index_a],
        );
    }

    @contours = ( [ \@ring, 0 ] );
}




##  Output
$log->notice( "Writing" );

my $name = 'Relation ' . join q{+}, @rel_ids;
$writer->save($outfile, $name, \@contours);

$log->notice( "All Ok" );
exit;



sub metric {
    my ($p1, $p2) = @_;

    my ($x1, $y1, $x2, $y2) = map {@$_} map { ref $_ ? $_ : $osm->{nodes}->{$_} } ($p1, $p2);
    confess Dump \@_ if !defined $y2;
    return (($x2-$x1)*cos( ($y2+$y1)/2/180*3.14159 ))**2 + ($y2-$y1)**2;
}




