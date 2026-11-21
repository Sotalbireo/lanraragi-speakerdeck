package LANraragi::Utils::SpeakerDeck;

use strict;
use warnings;
use utf8;

use Exporter 'import';
use Archive::Zip qw(AZ_OK);
use File::Spec;
use Mojo::DOM;
use Mojo::JSON qw(from_json);
use Mojo::URL;
use Time::HiRes qw(sleep);

our @EXPORT_OK = qw(normalize_post_url parse_post_html parse_player_html fetch_post download_post metadata_result);

use constant MAX_HTML_BYTES => 16 * 1024 * 1024;
use constant MAX_ARCHIVE_BYTES => 512 * 1024 * 1024;
use constant MAX_SLIDES => 2000;

sub normalize_post_url {
    my ($input) = @_;
    die "Expected a Speaker Deck post URL\n" unless defined $input && !ref $input;
    $input =~ s/^\s+|\s+$//g;
    my $url = Mojo::URL->new($input);
    _check_url($url, 'page');
    my @parts = @{ $url->path->parts };
    pop @parts if @parts && $parts[-1] eq '';
    die "Expected https://speakerdeck.com/author/deck\n"
      unless @parts == 2 && !grep { !length($_) || /[\s\/?#:\\]/ || /^\.{1,2}$/ } @parts;
    $url->scheme('https')->host('speakerdeck.com')->path('/' . join('/', @parts));
    $url->query(undef)->fragment(undef);
    return $url->to_string;
}

sub _check_url {
    my ($url, $kind) = @_;
    my $host = lc($url->host // '');
    my $scheme = lc($url->scheme // '');
    my $allowed = $kind eq 'asset' ? $host eq 'files.speakerdeck.com'
      : ($host eq 'speakerdeck.com' || $host eq 'www.speakerdeck.com');
    die "Unsupported Speaker Deck $kind URL\n"
      unless $allowed && ($scheme eq 'https' || $scheme eq 'http')
      && !defined($url->userinfo) && !defined($url->port);
    return $url;
}

sub _asset_url {
    my ($input, $base, $id) = @_;
    my $url = Mojo::URL->new($input)->to_abs(Mojo::URL->new($base));
    _check_url($url, 'asset');
    die "Asset belongs to a different Speaker Deck post\n"
      unless $url->path->to_string =~ m{\A/presentations/\Q$id\E/[^/]+\z}i;
    $url->scheme('https')->fragment(undef);
    return $url->to_string;
}

sub _text {
    my ($value) = @_;
    return '' unless defined $value && !ref $value;
    $value =~ s/\s+/ /g;
    $value =~ s/^\s+|\s+$//g;
    return $value;
}

sub _plain_description {
    my ($value) = @_;
    return '' unless defined $value && !ref $value;
    if ($value =~ /<\/?[a-z][^>]*>/i) {
        my $dom = Mojo::DOM->new($value);
        $dom->find('script, style')->each(sub { $_->remove });
        $dom->find('br')->each(sub { $_->replace("\n") });
        $dom->find('p, div, li')->each(sub { $_->append_content("\n") });
        $value = $dom->all_text;
    }
    $value =~ s/\r\n?/\n/g;
    $value =~ s/[^\S\n]+/ /g;
    $value =~ s/^\s+|\s+$//g;
    return $value;
}

sub _json_nodes {
    my ($value) = @_;
    return map { _json_nodes($_) } @$value if ref($value) eq 'ARRAY';
    return () unless ref($value) eq 'HASH';
    return ($value, _json_nodes($value->{'@graph'}));
}

sub parse_post_html {
    my ($html, $requested_url) = @_;
    $requested_url = normalize_post_url($requested_url);
    my $dom = Mojo::DOM->new($html);
    my $canonical_node = $dom->at('link[rel="canonical"]');
    my $canonical = $canonical_node ? normalize_post_url($canonical_node->attr('href')) : $requested_url;
    my @embeds = $dom->find('.speakerdeck-embed[data-id]')->each;
    die "Speaker Deck post/player not found (unavailable or changed page structure)\n" unless @embeds;
    my $id = $embeds[0]->attr('data-id') // '';
    die "Invalid Speaker Deck post ID\n" unless $id =~ /\A[a-f0-9]{32}\z/i;
    die "Ambiguous Speaker Deck players\n" if grep { ($_->attr('data-id') // '') ne $id } @embeds;

    my $data = {};
    for my $script ($dom->find('script[type="application/ld+json"]')->each) {
        my $json = eval { from_json($script->text) };
        next if $@;
        for my $node (_json_nodes($json)) {
            my @types = ref($node->{'@type'}) eq 'ARRAY' ? @{ $node->{'@type'} } : ($node->{'@type'} // '');
            next unless grep { $_ eq 'PresentationDigitalDocument' } @types;
            if ($node->{url}) {
                my $candidate = eval { normalize_post_url($node->{url}) };
                next unless $candidate && $candidate eq $canonical;
            }
            $data = $node;
            last;
        }
        last if %$data;
    }
    my $meta = sub {
        my ($name) = @_;
        my $node = $dom->at(qq{meta[property="$name"]}) || $dom->at(qq{meta[name="$name"]});
        return $node ? ($node->attr('content') // '') : '';
    };
    my $heading = $dom->at('h1');
    my $title = _text($data->{name}) || _text($meta->('og:title')) || ($heading ? _text($heading->all_text) : '');
    my $description = _plain_description($data->{description}) || _plain_description($meta->('og:description'))
      || _plain_description($meta->('description'));
    my $description_node = $dom->at('.deck-description');
    $description ||= _plain_description($description_node->content) if $description_node;
    my $author = ref($data->{author}) eq 'ARRAY' ? $data->{author}[0] : $data->{author};
    my $author_name = ref($author) eq 'HASH' ? _text($author->{name}) : _text($author);
    $author_name ||= _text($meta->('og:author'));
    my $owner = Mojo::URL->new($canonical)->path->parts->[0];
    my @categories;
    if (ref($data->{keywords}) eq 'ARRAY') {
        @categories = map { _text($_) } @{ $data->{keywords} };
    } elsif (!ref($data->{keywords}) && defined $data->{keywords}) {
        @categories = map { _text($_) } split /,/, $data->{keywords};
    }
    unless (@categories) {
        @categories = map { _text($_->all_text) }
          grep { ($_->attr('href') // '') =~ m{\A/(?:c|category)/[^/]+/?\z} }
          $dom->find('main a[rel="tag"], article a[rel="tag"]')->each;
    }

    # Use explicitly published download links; never derive a PDF URL from the ID.
    my $pdf_url;
    for my $link ($dom->find('a[href]')->each) {
        my $label = join ' ', map { $link->attr($_) // '' } qw(title aria-label download);
        next unless $label =~ /download\s+pdf/i || defined($link->attr('download'));
        my $candidate = _asset_url($link->attr('href'), $canonical, $id);
        die "Unexpected Speaker Deck PDF download link\n" unless Mojo::URL->new($candidate)->path->to_string =~ /\.pdf\z/i;
        $pdf_url = $candidate;
        last;
    }
    if (!$pdf_url && ref($data->{associatedMedia}) eq 'HASH' && $data->{associatedMedia}{contentUrl}) {
        $pdf_url = _asset_url($data->{associatedMedia}{contentUrl}, $canonical, $id);
        die "Unexpected Speaker Deck PDF media URL\n" unless Mojo::URL->new($pdf_url)->path->to_string =~ /\.pdf\z/i;
    }
    my $date = _text($data->{datePublished});
    unless ($date) {
        my $time = $dom->at('time[itemprop="datePublished"][datetime]');
        $date = _text($time->attr('datetime')) if $time;
    }
    $date = $date =~ /\A(\d{4}-\d{2}-\d{2})(?:T|\z)/ ? $1 : '';
    return {
        url => $canonical, id => lc($id), title => $title, summary => $description,
        author => $owner, author_name => $author_name, date => $date,
        language => _text($data->{inLanguage}), categories => \@categories, pdf_url => $pdf_url,
    };
}

sub parse_player_html {
    my ($html, $post) = @_;
    my $dom = Mojo::DOM->new($html);
    my @slides = $dom->find('.js-sd-player-slides .js-sd-slide')->each;
    die "Speaker Deck slide list not found (unavailable or changed player structure)\n" unless @slides;
    die "Speaker Deck slide count exceeds limit\n" if @slides > MAX_SLIDES;
    my (@urls, %seen);
    for my $slide (@slides) {
        my $raw = $slide->attr('data-url');
        die "Missing Speaker Deck slide URL\n" unless defined $raw && length $raw;
        my $url = _asset_url($raw, $post->{url}, $post->{id});
        die "Preview image found instead of full slide\n" if Mojo::URL->new($url)->path->to_string =~ m{/preview_}i;
        die "Duplicate Speaker Deck slide URL\n" if $seen{$url}++;
        push @urls, $url;
    }
    return \@urls;
}

sub _request {
    my ($ua, $input, $kind, $limit) = @_;
    my $url = Mojo::URL->new($input);
    my $old_redirects = $ua->max_redirects;
    my $old_timeout = $ua->request_timeout;
    my $old_size = $ua->max_response_size;
    my ($result, $error);
    eval {
        $ua->max_redirects(0)->request_timeout(60)->max_response_size($limit);
        my $redirects = 0;
        my $attempt = 0;
        while (1) {
            _check_url($url, $kind);
            my ($tx, $res);
            my $ok = eval { $tx = $ua->get($url->to_string); $res = $tx->result; 1 };
            my $code = $res ? ($res->code // 0) : 0;
            if (!$ok || !$code || $code == 429 || ($code >= 500 && $code <= 599)) {
                die "Speaker Deck request failed after retries ($code): $url\n" if $attempt >= 2;
                my $delay = 2 ** $attempt++;
                my $retry_after = $res ? $res->headers->header('Retry-After') : undef;
                $delay = $retry_after if defined($retry_after) && $retry_after =~ /^\d+$/ && $retry_after > $delay;
                $delay = 30 if $delay > 30;
                sleep($delay);
                next;
            }
            if ($code == 301 || $code == 302 || $code == 303 || $code == 307 || $code == 308) {
                die "Too many Speaker Deck redirects\n" if ++$redirects > 5;
                my $location = $res->headers->location;
                die "Missing Speaker Deck redirect location\n" unless defined $location && length $location;
                $url = Mojo::URL->new($location)->to_abs($url);
                $attempt = 0;
                next;
            }
            die "Speaker Deck HTTP $code: $url\n" unless $res->is_success;
            die "Incomplete Speaker Deck response: $url\n" if $tx->error;
            die "Speaker Deck response exceeds size limit\n" if $res->content->asset->size > $limit;
            $result = $res;
            last;
        }
        1;
    } or $error = $@ || "Speaker Deck request failed\n";
    $ua->max_redirects($old_redirects)->request_timeout($old_timeout)->max_response_size($old_size);
    die $error if $error;
    return $result;
}

sub _html {
    my ($res) = @_;
    my $type = $res->headers->content_type // '';
    die "Expected Speaker Deck HTML page\n" unless $type =~ m{\A(?:text/html|application/xhtml\+xml)(?:;|\z)}i;
    return $res->dom->to_string;
}

sub fetch_post {
    my ($ua, $input) = @_;
    my $url = normalize_post_url($input);
    my $post = parse_post_html(_html(_request($ua, $url, 'page', MAX_HTML_BYTES)), $url);
    if (!$post->{title} || !$post->{author_name}) {
        my $endpoint = Mojo::URL->new('https://speakerdeck.com/oembed.json')->query(url => $post->{url});
        # oEmbed only supplements incomplete pages; an unavailable supplement is not fatal.
        my $oembed = eval { _request($ua, $endpoint->to_string, 'page', MAX_HTML_BYTES)->json };
        if (ref($oembed) eq 'HASH') {
            $post->{title} ||= _text($oembed->{title});
            $post->{author_name} ||= _text($oembed->{author_name});
        }
    }
    die "Speaker Deck post title not found\n" unless $post->{title};
    return $post;
}

sub _image_extension {
    my ($head) = @_;
    return 'jpg' if substr($head, 0, 3) eq "\xff\xd8\xff";
    return 'png' if substr($head, 0, 8) eq "\x89PNG\r\n\x1a\n";
    return 'gif' if $head =~ /\AGIF8[79]a/;
    return 'webp' if substr($head, 0, 4) eq 'RIFF' && substr($head, 8, 4) eq 'WEBP';
    die "Expected a Speaker Deck slide image, received unsupported data\n";
}

sub download_post {
    my ($ua, $input, $tempdir) = @_;
    die "Missing LANraragi temporary directory\n" unless defined $tempdir && -d $tempdir;
    my $post = fetch_post($ua, $input);
    if ($post->{pdf_url}) {
        my $res = _request($ua, $post->{pdf_url}, 'asset', MAX_ARCHIVE_BYTES);
        die "Expected PDF data from Speaker Deck\n" unless $res->content->asset->get_chunk(0, 5) eq '%PDF-';
        my $path = File::Spec->catfile($tempdir, "speakerdeck_$post->{id}.pdf");
        $res->content->asset->move_to($path) or die "Cannot save Speaker Deck PDF: $!\n";
        return $path;
    }

    my $player_url = "https://speakerdeck.com/player/$post->{id}";
    my $slides = parse_player_html(_html(_request($ua, $player_url, 'page', MAX_HTML_BYTES)), $post);
    my $zip = Archive::Zip->new;
    my ($total, @temporary_images);
    $total = 0;
    my $path = File::Spec->catfile($tempdir, "speakerdeck_$post->{id}.cbz");
    my $partial = "$path.part";
    my $ok = eval {
        for my $i (0 .. $#$slides) {
            sleep(0.25) if $i;
            my $res = _request($ua, $slides->[$i], 'asset', MAX_ARCHIVE_BYTES - $total);
            $total += $res->content->asset->size;
            die "Speaker Deck archive exceeds size limit\n" if $total >= MAX_ARCHIVE_BYTES;
            my $ext = _image_extension($res->content->asset->get_chunk(0, 16));
            my $name = sprintf('%06d.%s', $i + 1, $ext);
            my $image = File::Spec->catfile($tempdir, $name);
            push @temporary_images, $image;
            $res->content->asset->move_to($image) or die "Cannot save Speaker Deck slide: $!\n";
            my $member = $zip->addFile($image, $name) or die "Cannot add Speaker Deck slide to CBZ\n";
            $member->desiredCompressionMethod(Archive::Zip::COMPRESSION_STORED());
        }
        die "Cannot write Speaker Deck CBZ\n" unless $zip->writeToFileNamed($partial) == AZ_OK;
        rename($partial, $path) or die "Cannot finalize Speaker Deck CBZ: $!\n";
        1;
    };
    my $error = $@;
    unlink @temporary_images if @temporary_images;
    unlink $partial if -f $partial;
    die $error unless $ok;
    return $path;
}

sub metadata_result {
    my ($post) = @_;
    my @tags;
    my $add = sub {
        my ($namespace, $value) = @_;
        $value = _text($value);
        $value =~ s/,/ /g;
        $value = _text($value);
        push @tags, "$namespace:$value" if length $value;
    };
    $add->('provider', 'speakerdeck');
    $add->('source', $post->{url});
    $add->('author', $post->{author});
    $add->('date', $post->{date});
    $add->('language', $post->{language});
    $add->('category', $_) for @{ $post->{categories} // [] };
    my %seen;
    @tags = grep { !$seen{lc $_}++ } @tags;
    my %result = (tags => join(', ', @tags));
    $result{title} = $post->{title} if length($post->{title} // '');
    $result{summary} = $post->{summary} if length($post->{summary} // '');
    return %result;
}

1;
