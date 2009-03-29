#line 1
# $Id: CheckLib.pm,v 1.22 2008/03/12 19:52:50 drhyde Exp $

package Devel::CheckLib;

use strict;
use vars qw($VERSION @ISA @EXPORT);
$VERSION = '0.5';
use Config;

use File::Spec;
use File::Temp;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(assert_lib check_lib_or_exit);

# localising prevents the warningness leaking out of this module
local $^W = 1;    # use warnings is a 5.6-ism

_findcc(); # bomb out early if there's no compiler

#line 127

sub check_lib_or_exit {
    eval 'assert_lib(@_)';
    if($@) {
        warn $@;
        exit;
    }
}

sub assert_lib {
    my %args = @_;
    my (@libs, @libpaths, @headers, @incpaths);

    # FIXME: these four just SCREAM "refactor" at me
    @libs = (ref($args{lib}) ? @{$args{lib}} : $args{lib}) 
        if $args{lib};
    @libpaths = (ref($args{libpath}) ? @{$args{libpath}} : $args{libpath}) 
        if $args{libpath};
    @headers = (ref($args{header}) ? @{$args{header}} : $args{header}) 
        if $args{header};
    @incpaths = (ref($args{incpath}) ? @{$args{incpath}} : $args{incpath}) 
        if $args{incpath};

    # work-a-like for Makefile.PL's LIBS and INC arguments
    if(defined($args{LIBS})) {
        foreach my $arg (split(/\s+/, $args{LIBS})) {
            die("LIBS argument badly-formed: $arg\n") unless($arg =~ /^-l/i);
            push @{$arg =~ /^-l/ ? \@libs : \@libpaths}, substr($arg, 2);
        }
    }
    if(defined($args{INC})) {
        foreach my $arg (split(/\s+/, $args{INC})) {
            die("INC argument badly-formed: $arg\n") unless($arg =~ /^-I/);
            push @incpaths, substr($arg, 2);
        }
    }

    my @cc = _findcc();
    my @missing;

    # first figure out which headers we can't find ...
    for my $header (@headers) {
        my($ch, $cfile) = File::Temp::tempfile(
            'assertlibXXXXXXXX', SUFFIX => '.c'
        );
        print $ch qq{#include <$header>\nint main(void) { return 0; }\n};
        close($ch);
        my $exefile = File::Temp::mktemp( 'assertlibXXXXXXXX' ) . $Config{_exe};
        my @sys_cmd;
        # FIXME: re-factor - almost identical code later when linking
        if ( $Config{cc} eq 'cl' ) {                 # Microsoft compiler
            require Win32;
            @sys_cmd = (@cc, $cfile, "/Fe$exefile", (map { '/I'.Win32::GetShortPathName($_) } @incpaths));
        } elsif($Config{cc} =~ /bcc32(\.exe)?/) {    # Borland
            @sys_cmd = (@cc, (map { "-I$_" } @incpaths), "-o$exefile", $cfile);
        } else {                                     # Unix-ish
                                                     # gcc, Sun, AIX (gcc, cc)
            @sys_cmd = (@cc, $cfile, (map { "-I$_" } @incpaths), "-o", "$exefile");
        }
        warn "# @sys_cmd\n" if $args{debug};
        my $rv = $args{debug} ? system(@sys_cmd) : _quiet_system(@sys_cmd);
        push @missing, $header if $rv != 0 || ! -x $exefile; 
        _cleanup_exe($exefile);
        unlink $cfile;
    } 

    # now do each library in turn with no headers
    my($ch, $cfile) = File::Temp::tempfile(
        'assertlibXXXXXXXX', SUFFIX => '.c'
    );
    print $ch "int main(void) { return 0; }\n";
    close($ch);
    for my $lib ( @libs ) {
        my $exefile = File::Temp::mktemp( 'assertlibXXXXXXXX' ) . $Config{_exe};
        my @sys_cmd;
        if ( $Config{cc} eq 'cl' ) {                 # Microsoft compiler
            require Win32;
            my @libpath = map { 
                q{/libpath:} . Win32::GetShortPathName($_)
            } @libpaths; 
            @sys_cmd = (@cc, $cfile, "${lib}.lib", "/Fe$exefile", 
                        "/link", @libpath
            );
        } elsif($Config{cc} eq 'CC/DECC') {          # VMS
        } elsif($Config{cc} =~ /bcc32(\.exe)?/) {    # Borland
            my @libpath = map { "-L$_" } @libpaths;
            @sys_cmd = (@cc, "-o$exefile", "-l$lib", @libpath, $cfile);
        } else {                                     # Unix-ish
                                                     # gcc, Sun, AIX (gcc, cc)
            my @libpath = map { "-L$_" } @libpaths;
            @sys_cmd = (@cc, $cfile,  "-o", "$exefile", "-l$lib", @libpath);
        }
        warn "# @sys_cmd\n" if $args{debug};
        my $rv = $args{debug} ? system(@sys_cmd) : _quiet_system(@sys_cmd);
        push @missing, $lib if $rv != 0 || ! -x $exefile; 
        _cleanup_exe($exefile);
    } 
    unlink $cfile;

    my $miss_string = join( q{, }, map { qq{'$_'} } @missing );
    die("Can't link/include $miss_string\n") if @missing;
}

sub _cleanup_exe {
    my ($exefile) = @_;
    my $ofile = $exefile;
    $ofile =~ s/$Config{_exe}$/$Config{_o}/;
    unlink $exefile if -f $exefile;
    unlink $ofile if -f $ofile;
    unlink "$exefile\.manifest" if -f "$exefile\.manifest";
    return
}
    
sub _findcc {
    my @paths = split(/$Config{path_sep}/, $ENV{PATH});
    my @cc = split(/\s+/, $Config{cc});
    return @cc if -x $cc[0];
    foreach my $path (@paths) {
        my $compiler = File::Spec->catfile($path, $cc[0]) . $Config{_exe};
        return ($compiler, @cc[1 .. $#cc]) if -x $compiler;
    }
    die("Couldn't find your C compiler\n");
}

# code substantially borrowed from IPC::Run3
sub _quiet_system {
    my (@cmd) = @_;

    # save handles
    local *STDOUT_SAVE;
    local *STDERR_SAVE;
    open STDOUT_SAVE, ">&STDOUT" or die "CheckLib: $! saving STDOUT";
    open STDERR_SAVE, ">&STDERR" or die "CheckLib: $! saving STDERR";
    
    # redirect to nowhere
    local *DEV_NULL;
    open DEV_NULL, ">" . File::Spec->devnull 
        or die "CheckLib: $! opening handle to null device";
    open STDOUT, ">&" . fileno DEV_NULL
        or die "CheckLib: $! redirecting STDOUT to null handle";
    open STDERR, ">&" . fileno DEV_NULL
        or die "CheckLib: $! redirecting STDERR to null handle";

    # run system command
    my $rv = system(@cmd);

    # restore handles
    open STDOUT, ">&" . fileno STDOUT_SAVE
        or die "CheckLib: $! restoring STDOUT handle";
    open STDERR, ">&" . fileno STDERR_SAVE
        or die "CheckLib: $! restoring STDERR handle";

    return $rv;
}

#line 348

1;
