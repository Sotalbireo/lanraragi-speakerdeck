package LANraragi::Plugin::Metadata::SpeakerDeck;

use strict;
use warnings;

use LANraragi::Utils::SpeakerDeck qw(normalize_post_url fetch_post metadata_result);

sub plugin_info {
    return (
        name => 'Speaker Deck Metadata',
        type => 'metadata',
        namespace => 'speakerdeckmeta',
        author => 'Kyon Sasaki',
        version => '0.1.0',
        description => 'Imports title, description, author, publication date, category and explicit language from a Speaker Deck post.',
        oneshot_arg => 'Speaker Deck post URL (overrides existing source tags)',
        cooldown => 2,
        parameters => {},
    );
}

sub get_tags {
    shift;
    my ($info, $params) = @_;
    $params ||= {};
    my $oneshot = $params->{oneshot} // $info->{oneshot_param};
    my $url;
    if (defined $oneshot && $oneshot =~ /\S/) {
        $url = normalize_post_url($oneshot);
    } else {
        my %sources;
        for my $tag (split /,/, $info->{existing_tags} // '') {
            next unless $tag =~ /^\s*source:\s*(.*?)\s*$/i;
            my $source = $1;
            next unless $source =~ m{\Ahttps?://(?:www\.)?speakerdeck\.com(?:/|\z)}i;
            my $normalized = eval { normalize_post_url($source) };
            next unless $normalized;
            $sources{$normalized} = 1;
        }
        die "Multiple Speaker Deck source URLs; specify a post URL in the one-shot argument\n" if keys(%sources) > 1;
        ($url) = keys %sources;
    }
    return (tags => '') unless $url;
    return metadata_result(fetch_post($info->{user_agent}, $url));
}

1;
