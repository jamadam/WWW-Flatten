use strict;
use warnings;
use utf8;
use 5.010;
use lib 'lib';
use lib '/Users/sugamakeita/Documents/dev/WWW-Flatten/lib';
use lib '/Users/sugamakeita/Documents/dev/WWW-Crawler-Mojo/lib';
use Data::Dumper;
use Mojo::URL;
use WWW::Flatten;

my $basedir = './output/';
mkdir($basedir) || die "directory doesnt exists or not writeable";

my $ext_regex = qr{\.(css|png|gif|jpeg|jpg|pdf|js|json)$}i;

my $bot = WWW::Flatten->new(
    basedir => $basedir,
    max_conn => 1,
    wait_per_host => 3,
    peeping_port => 3000,
    depth => 3,
    filenames => {
        'https://github.com' => 'index.html',
    },
    is_target => sub {
        my $uri = Mojo::URL->new(shift->resolved_uri);
        return 1 if ($uri->path =~ $ext_regex);
        return 1 if ($uri->host eq 'assets-cdn.github.com');
        return 0;
    },
    normalize => sub {
        my $uri = Mojo::URL->new(shift);
        
        return $uri;
    }
);

$bot->on(start => sub {
    shift->say_start;
});

$bot->crawl;
