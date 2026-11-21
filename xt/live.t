use strict;
use warnings;

use Test::More;
BEGIN {
    plan skip_all => 'Set SPEAKERDECK_LIVE_TESTS=1 to fetch public decks and download their files'
      unless $ENV{SPEAKERDECK_LIVE_TESTS};
}

use File::Temp qw(tempdir);
use Mojo::UserAgent;
use Archive::Zip qw(AZ_OK);
use LANraragi::Utils::SpeakerDeck qw(fetch_post download_post metadata_result);

my @cases = (
    ['PDF', 'https://speakerdeck.com/pedronauck/reactjs-keep-simple-everything-can-be-a-component'],
    ['CBZ', 'https://speakerdeck.com/lemiorhan/10-git-anti-patterns-you-should-be-aware-of'],
);

for my $case (@cases) {
    my ($format, $url) = @$case;
    subtest "live $format" => sub {
        my $ua = Mojo::UserAgent->new;
        my $post = fetch_post($ua, $url);
        ok($post->{title}, 'found title');
        ok($post->{author}, 'found author account');
        my %metadata = metadata_result($post);
        like($metadata{tags}, qr/source:https:\/\/speakerdeck\.com\//, 'found canonical source');
        is(!!$post->{pdf_url}, $format eq 'PDF' ? !!1 : !!0, 'sample still offers expected format');
        my $dir = tempdir(CLEANUP => 1);
        my $path = download_post($ua, $url, $dir);
        ok(-s $path, 'downloaded nonempty archive');
        if ($format eq 'PDF') {
            like($path, qr/\.pdf$/, 'PDF file');
            open my $fh, '<:raw', $path or die $!;
            read $fh, my $header, 5;
            is($header, '%PDF-', 'PDF signature');
            close $fh;
        } else {
            like($path, qr/\.cbz$/, 'CBZ file');
            my $zip = Archive::Zip->new;
            is($zip->read($path), AZ_OK, 'valid ZIP archive');
            my @members = $zip->memberNames;
            ok(@members > 1, 'contains multiple slides');
            for my $i (0 .. $#members) {
                my $prefix = sprintf('%06d', $i + 1);
                like($members[$i], qr/^\Q$prefix\E\.(?:jpg|png|webp|gif)$/, 'page in reading order');
            }
            diag(scalar(@members) . ' slides downloaded');
        }
    };
}

done_testing;
