package WWW::Flatten;
use strict;
use warnings;
use utf8;
use 5.010;
use Mojo::Base 'WWW::Crawler::Mojo';
use Mojo::Util qw(md5_sum);
use Mojolicious::Types;
our $VERSION = '0.01';

has urls => sub { {} };
has filenames => sub { {} };
has 'basedir';
has is_target => sub { sub { 1 } };
has 'normalize';
has asset_name => sub { asset_number_generator(6) };
has retrys => sub { {} };
has max_retry => 3;
has types => sub {
    my $types;
    my %cat = %{Mojolicious::Types->new->types};
    while (my ($key, $val) = each %cat) {
        $types->{$_} = $key for (map { s/\;.*$//; lc $_ } @$val);
    }
    return $types;
};

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
        my ($self, $discover, $job, $res) = @_;
        
        $discover->();
        
        my $uri = $job->resolved_uri;
        my $cont = $res->body;
        my $type = $res->headers->content_type;
        
        if ($type && $type =~ qr{text/(html|xml)}) {
            my $base = $uri;
            if (my $base_tag = $res->dom->at('base')) {
                $base = resolve_href($base, $base_tag->attr('href'));
            }
            $cont = $res->dom;
            $self->flatten_html($cont, $base);
            $cont = $cont->to_string;
        } elsif ($type && $type =~ qr{text/css}) {
            $cont = $self->flatten_css($cont, $uri);
        }
        
        my $original = $job->original_uri;
        
        $self->save($original, $cont);
        say sprintf('created: %s => %s ',
                                    $self->filenames->{$original}, $original);
    });
    
    $self->on(refer => sub {
        my ($self, $enqueue, $job, $context) = @_;
        
        return unless ($self->is_target->($job, $context));
        
        my $uri = $job->resolved_uri;
        
        if (my $cb = $self->normalize) {
            $job->resolved_uri($uri = $cb->($uri));
        }
        
        $self->_regist_asset_name($uri);
        
        $enqueue->();
    });
    
    $self->on(error => sub {
        my ($self, $msg, $job) = @_;
        say $msg;
        my $md5 = md5_sum($job->resolved_uri->to_string);
        if (++$self->retrys->{$md5} < $self->max_retry) {
            $self->requeue($job);
            say "Re-scheduled";
        }
    });
    
    $self->SUPER::init;
}

sub get_href {
    my ($self, $base, $uri) = @_;
    my $fragment = ($uri =~ qr{(#.+)})[0] || '';
    my $abs = WWW::Crawler::Mojo::resolve_href($base, $uri);
    if (my $cb = $self->normalize) {
        $abs = $cb->($abs);
    }
    my $file = $self->filenames->{$abs};
    return './'. $file. $fragment if ($file);
    return $abs. $fragment;
}

my %tag_attributes = %WWW::Crawler::Mojo::tag_attributes;

sub flatten_html {
    my ($self, $dom, $base) = @_;
    
    $dom->find(join(',', keys %tag_attributes))->each(sub {
        my $dom = shift;
        for (@{$tag_attributes{$dom->type}}) {
            $dom->{$_} = $self->get_href($base, $dom->{$_}) if ($dom->{$_});
        }
    });
    
    $dom->find('meta[http\-equiv=Refresh]')->each(sub {
        my $dom = shift;
        if (my $href = $dom->{content} && ($dom->{content} =~ qr{URL=(.+)}i)[0]) {
            my $abs = $self->get_href($base, $1);
            $dom->{content} =~ s{URL=(.+)}{
                'URL='. $abs;
            }e;
        }
    });
    
    $dom->find('base')->remove();
    
    $dom->find('style')->each(sub {
        my $dom = shift;
        my $cont = $dom->content;
        $dom->content($self->flatten_css($cont, $base));
    });
}

sub flatten_css {
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

sub _regist_asset_name {
    my ($self, $uri) = @_;
    if (!$self->filenames->{$uri}) {
        $self->filenames->{$uri} = $self->asset_name->($uri);
        my $ext = ($uri->path =~ qr{\.(\w+)$})[0] || do {
            my $got = $self->ua->head($uri)->res->headers->content_type || '';
            $got =~ s/\;.*$//;
            $self->types->{lc $got};
        };
        $self->filenames->{$uri} .= ".$ext" if ($ext);
    }
}

1;

=head1 NAME

WWW::Flatten - Flatten a web pages deeply and make it portable

=head1 SYNOPSIS

    use strict;
    use warnings;
    use utf8;
    use 5.010;
    use Mojo::URL;
    use WWW::Flatten;
    
    my $basedir = './github/';
    mkdir($basedir);
    
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

WWW::Flatten is a web crawling tool for freezing pages into standalone.

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
