package WWW::Flatten;
use strict;
use warnings;
use utf8;
use 5.010;
use Mojo::Base 'WWW::Crawler::Mojo';
use Mojo::Util qw(md5_sum);
use Mojolicious::Types;
use Encode;
our $VERSION = '0.03';

has depth => 10;
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
        my ($self, $scrape, $job, $res) = @_;
        
        $scrape->();
        
        my $uri = $job->resolved_uri;
        my $type = $res->headers->content_type;
        my $original = $job->original_uri;
        
        if ($type && $type =~ qr{text/(html|xml)}) {
            my $encode = WWW::Crawler::Mojo::guess_encoding($res) || 'UTF-8';
            my $cont = Mojo::DOM->new(Encode::decode($encode, $res->body));
            my $base = $uri;
            
            if (my $base_tag = $cont->at('base')) {
                $base = resolve_href($base, $base_tag->attr('href'));
            }
            
            $self->flatten_html($cont, $base);
            $cont = $cont->to_string;
            $self->save($original, $cont, $encode);
        } elsif ($type && $type =~ qr{text/css}) {
            my $encode = WWW::Crawler::Mojo::guess_encoding($res) || 'UTF-8';
            my $cont = $self->flatten_css($res->body, $uri);
            $self->save($original, $cont, $encode);
        } else {
            $self->save($original, $res->body);
        }
        
        say sprintf('created: %s => %s ',
                                    $self->filenames->{$original}, $original);
    });
    
    $self->on(refer => sub {
        my ($self, $enqueue, $job, $context) = @_;
        
        return unless ($self->is_target->($job, $context));
        return unless ($job->depth <= $self->depth);
        
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

sub flatten_html {
    my ($self, $dom, $base) = @_;
    
    $dom->find(join(',', keys %{$self->element_handlers}))->each(sub {
        my $dom = shift;
        for ('href', 'ping','src','data') {
            $dom->{$_} = $self->get_href($base, $dom->{$_}) if ($dom->{$_});
        }
    });
    
    $dom->find('meta[content]')->each(sub {
        if ($_[0] =~ qr{http\-equiv="?Refresh"?}i && $_[0]->{content}) {
            $_[0]->{content} =~
                            s{URL=(.+)}{ 'URL='. $self->get_href($base, $1) }e;
        }
    });

    
    $dom->find('base')->each(sub {shift->remove});
    
    $dom->find('style')->each(sub {
        my $dom = shift;
        my $cont = $dom->content;
        $dom->content($self->flatten_css($cont, $base));
    });
    
    $dom->find('[style]')->each(sub {
        my $dom = shift;
        my $cont = $dom->{style};
        $dom->{style} = $self->flatten_css($dom->{style}, $base);
    });
    return $dom
}

sub flatten_css {
    my ($self, $cont, $base) = @_;
    $cont =~ s{url\((.+?)\)}{
        my $url = $1;
        $url =~ s/^(['"])// && $url =~ s/$1$//;
        'url('. $self->get_href($base, $url). ')';
    }egi;
    return $cont;
}

sub save {
    my ($self, $url, $content, $encode) = @_;
    my $fullpath = $self->basedir. $self->filenames->{$url};
    $content = Encode::encode($encode, $content) if $encode;
    open(my $OUT, '>', $fullpath);
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
    use WWW::Flatten;
    
    my $basedir = './github/';
    mkdir($basedir);
    
    my $bot = WWW::Flatten->new(
        basedir => $basedir,
        max_conn => 1,
        max_conn_per_host => 1,
        depth => 3,
        filenames => {
            'https://github.com' => 'index.html',
        },
        is_target => sub {
            my $uri = shift->resolved_uri;
            
            if ($uri =~ qr{\.(css|png|gif|jpeg|jpg|pdf|js|json)$}i) {
                return 1;
            }
            
            if ($uri->host eq 'assets-cdn.github.com') {
                return 1;
            }
            
            return 0;
        },
        normalize => sub {
            my $uri = shift;
            ...
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
