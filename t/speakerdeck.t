use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use FindBin;
use Encode qw(encode_utf8);
use MIME::Base64 qw(decode_base64);
use Mojo::JSON qw(encode_json);
use Mojo::Transaction::HTTP;
use Archive::Zip qw(AZ_OK);

use lib "$FindBin::Bin/../lib";
use LANraragi::Utils::SpeakerDeck qw(normalize_post_url parse_post_html parse_player_html fetch_post download_post metadata_result);
use LANraragi::Plugin::Download::SpeakerDeck;
use LANraragi::Plugin::Metadata::SpeakerDeck;

{
    package SpeakerDeckTestUA;
    sub new { bless { replies => [@_[1 .. $#_]], calls => [], max_redirects => 5, request_timeout => 0, max_response_size => 16777216 }, $_[0] }
    sub max_redirects { my $self = shift; return $self->{max_redirects} unless @_; $self->{max_redirects} = shift; return $self }
    sub request_timeout { my $self = shift; return $self->{request_timeout} unless @_; $self->{request_timeout} = shift; return $self }
    sub max_response_size { my $self = shift; return $self->{max_response_size} unless @_; $self->{max_response_size} = shift; return $self }
    sub get {
        my ($self, $url) = @_;
        push @{ $self->{calls} }, $url;
        my $reply = shift @{ $self->{replies} } or die "Unexpected HTTP request: $url\n";
        die "Expected $reply->{url}, got $url\n" if $reply->{url} && $reply->{url} ne $url;
        die "Simulated connection failure\n" if $reply->{disconnect};
        my $tx = Mojo::Transaction::HTTP->new;
        $tx->res->code($reply->{status} // 200);
        $tx->res->headers->content_type($reply->{type} // 'text/html; charset=UTF-8');
        $tx->res->headers->location($reply->{location}) if $reply->{location};
        $tx->res->headers->header('Retry-After' => $reply->{retry_after}) if defined $reply->{retry_after};
        $tx->res->body($reply->{body} // '');
        return $tx;
    }
}

# Keep retry/backoff and inter-slide delay deterministic in offline tests.
my @delays;
no warnings 'redefine';
local *LANraragi::Utils::SpeakerDeck::sleep = sub { push @delays, $_[0] };
use warnings 'redefine';

my $url = 'https://speakerdeck.com/alice/designing-systems';
my $id = '11111111111111111111111111111111';
my $asset = "https://files.speakerdeck.com/presentations/$id";
sub fixture {
    open my $fh, '<:encoding(UTF-8)', "$FindBin::Bin/fixtures/$_[0]" or die $!;
    local $/;
    return <$fh>;
}
my $pdf_html = fixture('post-pdf.html');
my $cbz_html = fixture('post-no-pdf.html');
my $player = fixture('player.html');
my $png = decode_base64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1kAAAAASUVORK5CYII=');
sub page { return { body => encode_utf8($_[0]) } }
sub image { return { body => $png, type => 'image/png' } }
sub error_like {
    my ($code, $pattern, $name) = @_;
    my $ok = eval { $code->(); 1 };
    ok(!$ok, "$name fails");
    like($@, $pattern, "$name reports cause");
}
sub slurp_bytes {
    open my $fh, '<:raw', $_[0] or die $!;
    local $/;
    return <$fh>;
}

subtest 'URL validation' => sub {
    is(normalize_post_url(" http://www.speakerdeck.com/alice/designing-systems/?slide=2#3 \n"), $url, 'normalizes transport, host, trailing slash and slide selectors');
    for my $bad ('https://example.com/alice/deck', 'https://speakerdeck.com.evil.test/alice/deck',
        'https://speakerdeck.com/alice', 'https://speakerdeck.com/alice/deck/extra',
        'https://user:pass@speakerdeck.com/alice/deck', 'https://speakerdeck.com:443/alice/deck',
        'file://speakerdeck.com/alice/deck', 'https://speakerdeck.com/alice/%2Fetc',
        'https://speakerdeck.com/alice/..', 'https://speakerdeck.com/alice/%2e%2e') {
        error_like(sub { normalize_post_url($bad) }, qr/Expected|Unsupported/, $bad);
    }
};

subtest 'post HTML and metadata mapping' => sub {
    my $post = parse_post_html($pdf_html, $url);
    is($post->{id}, $id, 'uses primary deck ID, ignores related cards');
    is($post->{title}, '設計と Perl', 'decodes Unicode JSON-LD graph and skips unrelated document');
    is($post->{author}, 'alice', 'author account comes from canonical URL');
    is($post->{author_name}, 'Alice Example', 'extracts display name');
    is($post->{date}, '2026-11-01', 'uses publication date');
    is($post->{language}, 'ja', 'uses explicit language');
    like($post->{summary}, qr/日本語の説明。\s+Second paragraph\./, 'description is plain Unicode text');
    unlike($post->{summary}, qr/<p>/, 'description strips markup');
    is($post->{pdf_url}, "$asset/original.pdf", 'finds explicit PDF download');
    my %metadata = metadata_result($post);
    is($metadata{title}, '設計と Perl', 'returns title');
    like($metadata{tags}, qr/author:alice/, 'returns author tag');
    like($metadata{tags}, qr/category:Design Systems/, 'commas inside tags cannot create new tags');
    like($metadata{tags}, qr/date:2026-11-01/, 'returns publication date tag');
    my $no_pdf = parse_post_html($cbz_html, $url);
    is($no_pdf->{title}, '公開スライド & Perl', 'Open Graph fallback decodes entities');
    ok(!$no_pdf->{pdf_url}, 'encodingFormat alone does not imply PDF availability');
    my $sparse = $cbz_html;
    $sparse =~ s{<script.*?</script>}{}sg;
    my $sparse_post = parse_post_html($sparse, $url);
    is_deeply($sparse_post->{categories}, [], 'does not import navigation categories');
    my %sparse_metadata = metadata_result($sparse_post);
    unlike($sparse_metadata{tags}, qr/(date|language|category):/, 'omits missing metadata instead of guessing');
    my $broken_json = $sparse . '<script type="application/ld+json">broken</script>';
    is(parse_post_html($broken_json, $url)->{title}, $no_pdf->{title}, 'malformed JSON-LD falls back to OG');
    (my $dom_only = $sparse) =~ s{<meta property="og:description"[^>]*>}{};
    $dom_only .= '<div class="deck-description"><p>Body <b>description</b>.</p><script>secret()</script></div><time itemprop="datePublished" datetime="2025-03-04T10:00:00Z"></time>';
    my $dom_post = parse_post_html($dom_only, $url);
    like($dom_post->{summary}, qr/Body description\./, 'description falls back to post body');
    unlike($dom_post->{summary}, qr/secret/, 'description excludes scripts');
    is($dom_post->{date}, '2025-03-04', 'uses explicitly marked publication date in DOM');
    my %empty = metadata_result({ url => $url, categories => [] });
    ok(!exists $empty{summary}, 'missing description does not clear existing summary');
    my %deduplicated = metadata_result({ url => $url, categories => ['Programming', 'programming'] });
    is(scalar(() = $deduplicated{tags} =~ /category:/g), 1, 'deduplicates equivalent categories');
    error_like(sub { parse_post_html('<h1>Access denied</h1>', $url) }, qr/post\/player not found/, 'unrecognized HTML');
    my $foreign_pdf = $pdf_html;
    $foreign_pdf =~ s{files\.speakerdeck\.com}{evil.test}g;
    error_like(sub { parse_post_html($foreign_pdf, $url) }, qr/Unsupported/, 'foreign asset host');
};

subtest 'player parsing' => sub {
    my $post = parse_post_html($cbz_html, $url);
    is_deeply(parse_player_html($player, $post), ["$asset/slide_0.jpg?100&x=1", "$asset/slide_1.jpg?101"], 'uses full image URLs in document order, preserves query');
    error_like(sub { parse_player_html('<html>blocked</html>', $post) }, qr/slide list not found/, 'missing player');
    (my $bad = $player) =~ s/data-url=/data-missing=/;
    error_like(sub { parse_player_html($bad, $post) }, qr/Missing.*slide URL/, 'missing slide URL');
    ($bad = $player) =~ s{/slide_0.jpg}{/preview_slide_0.jpg};
    error_like(sub { parse_player_html($bad, $post) }, qr/Preview/, 'preview image');
    ($bad = $player) =~ s/$id/22222222222222222222222222222222/g;
    error_like(sub { parse_player_html($bad, $post) }, qr/different.*post/, 'another deck image');
    ($bad = $player) =~ s{slide_1.jpg\?101}{slide_0.jpg?100&amp;x=1};
    error_like(sub { parse_player_html($bad, $post) }, qr/Duplicate/, 'duplicate image');
};

subtest 'original PDF is unchanged; failures do not become CBZ' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $bytes = "%PDF-1.4\noriginal bytes\x00\xff\n%%EOF\n";
    my $ua = SpeakerDeckTestUA->new(page($pdf_html), { url => "$asset/original.pdf", type => 'application/pdf', body => $bytes });
    my %result = LANraragi::Plugin::Download::SpeakerDeck->provide_url({ url => $url, user_agent => $ua, tempdir => $dir });
    like($result{file_path}, qr/speakerdeck_$id\.pdf$/, 'returns local PDF');
    is(slurp_bytes($result{file_path}), $bytes, 'preserves exact PDF bytes');
    is(scalar @{ $ua->{calls} }, 2, 'only fetches page and PDF');
    is($ua->max_redirects, 5, 'restores redirect configuration');
    is($ua->request_timeout, 0, 'restores timeout');
    is($ua->max_response_size, 16777216, 'restores size limit');
    for my $status (403, 404) {
        my $failed = SpeakerDeckTestUA->new(page($pdf_html), { status => $status });
        error_like(sub { download_post($failed, $url, $dir) }, qr/HTTP $status/, "PDF HTTP $status");
        is(scalar @{ $failed->{calls} }, 2, 'does not fetch player');
    }
    my $failed = SpeakerDeckTestUA->new(page($pdf_html), page('<html>not a PDF</html>'));
    error_like(sub { download_post($failed, $url, $dir) }, qr/Expected PDF/, 'HTML masquerading as PDF');
    is(scalar @{ $failed->{calls} }, 2, 'invalid PDF does not fetch player');
    $failed = SpeakerDeckTestUA->new(page($pdf_html), ({ disconnect => 1 }) x 3);
    error_like(sub { download_post($failed, $url, $dir) }, qr/after retries/, 'PDF transport failure');
    is(scalar @{ $failed->{calls} }, 4, 'transport retries are bounded and do not fetch player');
};

subtest 'CBZ fallback and atomic failure' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ua = SpeakerDeckTestUA->new(page($cbz_html), { %{ page($player) }, url => "https://speakerdeck.com/player/$id" }, image(), image());
    my $path = download_post($ua, $url, $dir);
    like($path, qr/\.cbz$/, 'creates CBZ when no PDF is offered');
    my $zip = Archive::Zip->new;
    is($zip->read($path), AZ_OK, 'archive is readable');
    is_deeply([$zip->memberNames], ['000001.png', '000002.png'], 'all pages in stable reading order, format detected from bytes');
    is($zip->contents('000001.png'), $png, 'image bytes are unchanged');
    ok(!-e "$path.part", 'no partial archive remains');
    ok(!-e File::Spec->catfile($dir, '000001.png'), 'temporary images removed');
    my $failed_dir = tempdir(CLEANUP => 1);
    my $failed = SpeakerDeckTestUA->new(page($cbz_html), page($player), image(), { status => 404 });
    error_like(sub { download_post($failed, $url, $failed_dir) }, qr/HTTP 404/, 'missing second slide');
    opendir my $dh, $failed_dir or die $!;
    is_deeply([grep { !/^\.{1,2}$/ } readdir $dh], [], 'no partial CBZ or downloaded images retained');
    closedir $dh;
    $failed = SpeakerDeckTestUA->new(page($cbz_html), page($player), page('<html>image error</html>'));
    error_like(sub { download_post($failed, $url, $failed_dir) }, qr/slide image/, 'non-image slide response');
};

subtest 'HTTP retries, redirects and oEmbed' => sub {
    @delays = ();
    my $ua = SpeakerDeckTestUA->new({ status => 429, retry_after => 1 }, { status => 503 }, page($pdf_html));
    is(fetch_post($ua, $url)->{id}, $id, 'retries rate limit and temporary server error');
    is(scalar @{ $ua->{calls} }, 3, 'bounded successful retry sequence');
    is_deeply(\@delays, [1, 2], 'uses finite backoff');
    @delays = ();
    $ua = SpeakerDeckTestUA->new({ status => 429, retry_after => 120 }, page($pdf_html));
    fetch_post($ua, $url);
    is_deeply(\@delays, [30], 'caps Retry-After at thirty seconds');
    $ua = SpeakerDeckTestUA->new(({ status => 500 }) x 3);
    error_like(sub { fetch_post($ua, $url) }, qr/after retries/, 'persistent server error');
    is(scalar @{ $ua->{calls} }, 3, 'at most two retries');
    is($ua->max_redirects, 5, 'restores UA configuration on failure');
    $ua = SpeakerDeckTestUA->new({ status => 302, location => "$url?redirected=1" }, page($pdf_html));
    is(fetch_post($ua, $url)->{id}, $id, 'follows allowed redirect');
    $ua = SpeakerDeckTestUA->new({ status => 302, location => 'http://127.0.0.1/private' });
    error_like(sub { fetch_post($ua, $url) }, qr/Unsupported/, 'redirect outside allowed hosts');
    is(scalar @{ $ua->{calls} }, 1, 'rejects redirect before network access');
    $ua = SpeakerDeckTestUA->new(({ status => 302, location => $url }) x 6);
    error_like(sub { fetch_post($ua, $url) }, qr/Too many.*redirects/, 'redirect loop');
    $ua = SpeakerDeckTestUA->new({ type => 'application/json', body => '{}' });
    error_like(sub { fetch_post($ua, $url) }, qr/Expected.*HTML/, 'non-HTML post response');
    my $sparse = '<div class="speakerdeck-embed" data-id="' . $id . '"></div>';
    $ua = SpeakerDeckTestUA->new(page($sparse), { type => 'application/json', body => encode_json({ title => 'oEmbed title', author_name => 'Alice' }) });
    is(fetch_post($ua, $url)->{title}, 'oEmbed title', 'oEmbed supplements missing title');
    like($ua->{calls}[1], qr{^https://speakerdeck.com/oembed.json\?url=}, 'uses documented endpoint');
    my $missing_author = '<meta property="og:title" content="Title">' . $sparse;
    $ua = SpeakerDeckTestUA->new(page($missing_author), { status => 404 });
    is(fetch_post($ua, $url)->{title}, 'Title', 'failed optional oEmbed preserves available title');
};

subtest 'metadata source resolution and plugin contract' => sub {
    my %dl = LANraragi::Plugin::Download::SpeakerDeck->plugin_info;
    my %md = LANraragi::Plugin::Metadata::SpeakerDeck->plugin_info;
    isnt($dl{namespace}, $md{namespace}, 'unique plugin namespaces');
    is($dl{type}, 'download', 'Downloader type');
    is($md{type}, 'metadata', 'Metadata type');
    like($url, qr/$dl{url_regex}/, 'Downloader regex matches a post');
    unlike('https://speakerdeck.com/alice', qr/$dl{url_regex}/, 'regex excludes profiles');
    my $ua = SpeakerDeckTestUA->new(page($pdf_html));
    my %result = LANraragi::Plugin::Metadata::SpeakerDeck->get_tags({ user_agent => $ua, existing_tags => "topic:test, source:$url?slide=2#3" }, {});
    is($result{title}, '設計と Perl', 'fetches post selected by source tag');
    like($result{tags}, qr/\Qsource:$url\E/, 'returns canonical source');
    my $no_requests = SpeakerDeckTestUA->new;
    %result = LANraragi::Plugin::Metadata::SpeakerDeck->get_tags({ user_agent => $no_requests, existing_tags => 'source:https://other.example/deck' }, {});
    is_deeply(\%result, { tags => '' }, 'unrelated archive is a no-op');
    is(scalar @{ $no_requests->{calls} }, 0, 'no HTTP requests for unrelated archive');
    my $info = { user_agent => $no_requests, existing_tags => "source:$url, source:https://speakerdeck.com/bob/another" };
    error_like(sub { LANraragi::Plugin::Metadata::SpeakerDeck->get_tags($info, {}) }, qr/Multiple.*source URLs/, 'ambiguous sources');
    $ua = SpeakerDeckTestUA->new(page($pdf_html));
    %result = LANraragi::Plugin::Metadata::SpeakerDeck->get_tags({ %$info, user_agent => $ua }, { oneshot => $url });
    is($result{title}, '設計と Perl', 'one-shot overrides ambiguous sources');
    error_like(sub { LANraragi::Plugin::Metadata::SpeakerDeck->get_tags($info, { oneshot => 'https://evil.test/a/b' }) }, qr/Unsupported/, 'invalid explicit override');
    $ua = SpeakerDeckTestUA->new(page($pdf_html));
    %result = LANraragi::Plugin::Metadata::SpeakerDeck->get_tags({ user_agent => $ua, oneshot_param => $url }, {});
    is($result{title}, '設計と Perl', 'accepts infohash one-shot argument');
    $ua = SpeakerDeckTestUA->new(page($pdf_html));
    %result = LANraragi::Plugin::Metadata::SpeakerDeck->get_tags({ user_agent => $ua, existing_tags => "source:$url#1, source:$url#2" }, {});
    is(scalar @{ $ua->{calls} }, 1, 'equivalent source URLs are not ambiguous');
};

done_testing;
