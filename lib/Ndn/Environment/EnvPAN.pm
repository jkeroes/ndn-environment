package Ndn::Environment::EnvPAN;
use strict;
use warnings;

use Config;
use base 'Exporter';
use Carp qw/croak confess/;
use File::Temp qw/tempfile/;

use Ndn::Environment;
use Ndn::Environment::Util qw/run_in_config_env/;

our @EXPORT_OK = qw(
    install_module
    inject_module
);

my %NESTING;

sub _module_url {
    my ($source) = @_;

    my $perl = NDN_ENV->perl;

    my $code = <<"    EOT";
        require MetaCPAN::API;
        my \$c = MetaCPAN::API->new;
        my \$dist = \$c->module("$source")->{distribution} || die "No dist found";
        my \$rel = \$c->release( distribution => \$dist )  || die "No release found";
        print \$rel->{download_url} . "\\n";
    EOT

    chomp( my $url = `$perl -e '$code'` );

    return $url;
}

sub inject_module {
    my @modules = @_;

    my $inject = 'envpan/bin/orepan2-inject';
    my $index  = 'envpan/bin/orepan2-indexer';

    run_in_config_env {
        my $cwd = NDN_ENV->cwd;
        local %ENV = %ENV;
        local $ENV{PERL5LIB} = "$cwd/envpan/lib/perl5:envpan/lib/perl5/x86_64-linux:$ENV{PERL5LIB}";

        for my $mod (@modules) {
            my $src = $mod =~ '/' ? $mod : _module_url($mod);

            print "Injecting $mod...\n";
            system("$inject --no-generate-index $src envpan") && die $!;
        }

        print "Rebuilding index...\n";
        system("$index envpan >/dev/null 2>&1") && die $!;
    };
}

sub install_module {
    my ( $module, %params ) = @_;

    $NESTING{$module}++;
    die "Infinite nest?" if $NESTING{$module} > 3;

    confess "You must specify a 'from' param of either 'cpan' or 'mirror'"
        unless $params{from};

    #<<< no-tidy
    my @cpanm_args = $params{from} eq 'cpan' ? () : (
        "--mirror-only",
        "--mirror=file://" . NDN_ENV->cwd . "/envpan",
    );
    #>>>

    push @cpanm_args => "-l '$params{local_lib}'"
        if $params{local_lib};

    run_in_config_env {
        local %ENV = ( %ENV, %{$params{env}})
            if $params{env};

        my $build_dir = NDN_ENV->build_dir;
        my $perl_dir = NDN_ENV->perl_dir;
        my $perl     = NDN_ENV->perl;
        my $cpanm    = NDN_ENV->temp . '/cpanm';

        my $command = join " " => (
            $perl,
            $cpanm,
            $params{cpanm_args} ? $params{cpanm_args} : (),
            @cpanm_args,
            $module,
        );

        print "Installing Module: $module\n";

        my ($th, $tf) = tempfile;
        close($th);

        system( "$command 2>&1 | tee $tf" ) && die "tee command failed: $!";

        my (@need, $fail);
        open( $th, '<', $tf ) || die "Could not open '$tf': $!";
        while (my $line = <$th>) {
            $fail ||= $line =~ m/Bailing out the installation/;

            if( $line =~ m{Installing \S+ failed\. See (\S+) for details}) {
                die "Error, check $1\n";
            }

            if( my @modules = ($line =~ m/Module '(\S+)' is not installed/g)) {
                push @need => @modules;
                next;
            }

            next unless $line =~ m/Finding (\S+) \([^\)]*\) on mirror/
                || $line =~ m/Installed version \([^\)]*\) of (\S+) is not in range/;
            
            push @need => $1;
        }

        if (@need || $fail) {
            die "cpanm failed" unless $params{auto_inject};

            if (@need) {
                my %seen;
                @need = grep { $_ && !$seen{$_}++ } @need;
                print "Found deps: " . join( ", ", @need ) . "\n";
                inject_module(@need);
                install_module( $_, %params ) for grep { $_ ne $module } @need;
                install_module( $module, %params );
            }
            else {
                die "Error installing $module";
            }
        }

        system("perl -p -i -e 's{$build_dir}{}g' $perl_dir/bin/*")
            && die $!;
    };

    $NESTING{$module}--;
}

1;

__END__

=head1 COPYRIGHT

Copyright (C) 2013 New Dream Network LLC

Ndn-Environment is free software; FreeBSD License

NDN-Environment is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the license for more details.

