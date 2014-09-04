package WWW::FreezeBot;
use strict;
use warnings;
use utf8;
use 5.010;
use Mojo::Base 'Mojo::Crawler';
use Mojo::Util qw(md5_sum);
use Mojo::Crawler;
our $VERSION = '0.01';

has urls => sub { {} };
has filenames => sub { {} };
has 'basedir';
has is_target => sub { sub { 1 } };
has 'normalize';
has asset_name => sub { asset_number_generator(6) };

sub asset_number_generator {
    my $digit = (shift || 6);
    my $num = 0;
    return sub {
        return sprintf("%0${digit}d", $num++);
    };
}

sub asset_hash_generator {
    my $len = (shift || 6);
    my %uniq;
    return sub {
        my $md5 = md5_sum(shift);
        my $len = $len;
        my $key;
        do { $key = substr($md5, 0, $len++) } while (exists $uniq{$key});
        $uniq{$key} = undef;
        return $key;
    };
}

sub init {
    my ($self) = @_;
    
    for (keys %{$self->filenames}) {
        $self->enqueue($_);
    }
    
    $self->on(res => sub {
        my ($self, $discover, $queue, $res) = @_;
        my $uri = $queue->resolved_uri;
        
        my $cont = $res->body;
        
        $discover->();
        
        my $base = $queue->resolved_uri;
        my $type = $res->headers->content_type;
        
        if ($type && $type =~ qr{text/(html|xml)}) {
            if (my $base_tag = $res->dom->at('base')) {
                $base = resolve_href($base, $base_tag->attr('href'));
            }
            $cont = $res->dom;
            $self->freeze_html($cont, $base);
            $cont = $cont->to_string;
        } elsif ($type && $type =~ qr{text/css}) {
            $cont = $self->freeze_css($cont, $base);
        }
        
        $self->save($queue->resolved_uri, $cont);
        say sprintf('created: %s => %s ', $self->filenames->{$uri}, $uri);
    });
    
    $self->on(refer => sub {
        my ($self, $enqueue, $queue, $context) = @_;
        
        return unless ($self->is_target->($queue));
        
        my $uri = $queue->resolved_uri;
        
        if (my $cb = $self->normalize) {
            $queue->resolved_uri($uri = $cb->($uri));
        }
        
        if (!$self->filenames->{$uri}) {
            $self->filenames->{$uri} = $self->asset_name->($uri).
                                    '.'. (($uri =~ qr{\.(\w+)$})[0] || 'html');
        }
        
        $enqueue->();
    });
    
    $self->on(error => sub {
        my ($self, $msg, $queue) = @_;
        say $msg;
        say "Re-scheduled";
        $self->enqueue($queue);
    });
    
    $self->SUPER::init;
}

sub get_href {
    my ($self, $base, $uri) = @_;
    my $fragment = ($uri =~ qr{(#.+)})[0] || '';
    my $abs = Mojo::Crawler::resolve_href($base, $uri);
    if (my $cb = $self->normalize) {
        $abs = $cb->($abs);
    }
    my $file = $self->filenames->{$abs};
    return './'. $file. $fragment if ($file);
    return $abs. $fragment;
}

sub freeze_html {
    my ($self, $dom, $base) = @_;
    
    $dom->find('form, script, link, a, img, area, embed, frame, iframe, input,
                                    meta[http\-equiv=Refresh]')->each(sub {
        my $dom = shift;
        
        for my $name ('action','href','src','content') {
            if ($dom->{$name}) {
                if ($name eq 'content' && ($dom->{content} =~ qr{URL=(.+)}i)[0]) {
                    my $abs = $self->get_href($base, $1);
                    $dom->{content} =~ s{URL=(.+)}{
                        'URL='. $abs;
                    }e;
                } else {
                    $dom->{$name} = $self->get_href($base, $dom->{$name});
                }
                last;
            }
        }
    });
    
    $dom->find('base')->remove();
    
    $dom->find('style')->each(sub {
        my $dom = shift;
        my $cont = $dom->content;
        $dom->content($self->freeze_css($cont, $base));
    });
}

sub freeze_css {
    my ($self, $cont, $base) = @_;
    $cont =~ s{url\(['"]?(.+?)['"]?\)}{
        'url('. $self->get_href($base, $1). ')';
    }eg;
    return $cont;
}

sub save {
    my ($self, $url, $content) = @_;
    my $fullpath = $self->basedir. $self->filenames->{$url};
    open(my $OUT, utf8::is_utf8($content) ? '>:utf8' : '>', $fullpath);
    print $OUT $content;
    close($OUT);
}

1;

=head1 NAME

WWW::FreezeBot - Freeze a web pages deeply and make it portable

=head1 SYNOPSIS

    use strict;
    use warnings;
    use utf8;
    use 5.010;
    use Mojo::URL;
    use WWW::FreezeBot;
    
    my $basedir = './github/';
    mkdir($basedir);
    
    my $ext_regex = qr{\.(css|png|gif|jpeg|jpg|pdf|js|json)$}i;
    
    my $bot = WWW::FreezeBot->new(
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
            
            if ($uri =~ $ext_regex) {
                return 1;
            }
            
            if ($uri->host eq 'assets-cdn.github.com') {
                return 1;
            }
            
            return 0;
        },
        normalize => sub {
            my $uri = Mojo::URL->new(shift);
            
            return $uri;
        }
    );
    
    $bot->crawl;

=head1 DESCRIPTION

WWW::Freezebot is a web crawling tool for freezing pages into standalone.

This software is considered to be alpha quality and isn't recommended for regular usage.

=head1 ATTRIBUTES

=head1 METHODS

=head1 AUTHOR

Sugama Keita, E<lt>sugama@jamadam.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) jamadam

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
