requires 'perl', '5.036';
requires 'Mojolicious', '9.39';
requires 'Archive::Zip', '1.68';

on 'test' => sub {
    requires 'Test::More', '0.98';
};
