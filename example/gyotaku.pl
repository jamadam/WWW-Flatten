#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use WWW::Crawler::Mojo;
use 5.10.0;

my $bot = WWW::Crawler::Mojo->new;
$bot->on(res => sub {
    my ($bot, $scrape, $job, $res) = @_;
    say sprintf('fetching %s resulted status %s', $job->url, $res->code);
    $scrape->();
});
$bot->on(refer => sub {
    my ($bot, $enqueue, $job, $context) = @_;
    $enqueue->();
});
$bot->on(error => sub {
    my ($msg, $job) = @_;
    say $msg;
    say "Re-scheduled";
    $bot->enqueue($job);
});
$bot->enqueue('http://example.com/');
$bot->crawl;
