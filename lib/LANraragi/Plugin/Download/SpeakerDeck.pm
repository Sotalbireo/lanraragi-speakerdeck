package LANraragi::Plugin::Download::SpeakerDeck;

use strict;
use warnings;

use LANraragi::Utils::SpeakerDeck qw(download_post);

sub plugin_info {
    return (
        name => 'Speaker Deck Downloader',
        type => 'download',
        namespace => 'speakerdeckdl',
        author => 'Kyon Sasaki',
        version => '0.1.0',
        description => 'Downloads the original PDF of a public Speaker Deck post, or creates a CBZ from public slides when no PDF download is offered.',
        url_regex => '^https?://(?:www\.)?speakerdeck\.com/[^/?#]+/[^/?#]+/?(?:[?#].*)?$',
        parameters => {},
    );
}

sub provide_url {
    shift;
    my ($info, %settings) = @_;
    return (file_path => download_post($info->{user_agent}, $info->{url}, $info->{tempdir}));
}

1;
