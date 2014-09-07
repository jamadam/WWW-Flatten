use strict;
use warnings;
use utf8;
use 5.010;
use Data::Dumper;
use Mojo::URL;
use WWW::Flatten;

my $basedir = './output/';
-d $basedir || mkdir($basedir) || 'Current directory is not writable';

my $url = $ARGV[0];

my $bot = WWW::Flatten->new(
    basedir => $basedir,
    max_conn => 1,
    wait_per_host => 3,
    peeping_port => 3000,
    depth => 3,
    filenames => {
        $url => 'index.html',
    },
    is_target => sub {
        my ($queue, $context) = @_;
        return ((ref $context) ne 'Mojo::DOM' || $context->type !~ qr{^(form|a)$});
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
