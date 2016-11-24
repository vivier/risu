#!/usr/bin/perl -w
###############################################################################
# Copyright (c) 2016 Laurent Vivier
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Eclipse Public License v1.0
# which accompanies this distribution, and is available at
# http://www.eclipse.org/legal/epl-v10.html
###############################################################################


# risugen -- generate a test binary file for use with risu
# See 'risugen --help' for usage information.
package risugen_m68k;

use strict;
use warnings;

require Exporter;

our @ISA    = qw(Exporter);
our @EXPORT = qw(write_test_code);

my $periodic_reg_random = 1;

my $bytecount;
#
# Maximum alignment restriction permitted for a memory op.
my $MAXALIGN = 64;

sub open_bin
{
    my ($fname) = @_;
    open(BIN, ">", $fname) or die "can't open %fname: $!";
    $bytecount = 0;
}

sub close_bin
{
    close(BIN) or die "can't close output file: $!";
}

sub insn32($)
{
    my ($insn) = @_;
    print BIN pack("N", $insn);
    $bytecount += 4;
}

sub insn16($)
{
    my ($insn) = @_;
    print BIN pack("n", $insn);
    $bytecount += 2;
}

sub write_risuop($)
{
    my ($op) = @_;
    insn32(0x4afc7000 | $op);
}

sub write_mov_ccr($)
{
    my ($imm) = @_;
    insn16(0x44fc);
    insn16($imm);
}

sub write_movb_di($$)
{
    my ($r, $imm) = @_;

    # move.b #imm,%dr
    insn16(0x103c | ($r << 9));
    insn16($imm)
}

sub write_mov_di($$)
{
    my ($r, $imm) = @_;

    # move.l #imm,%dr
    insn16(0x203c | ($r << 9));
    insn32($imm)
}

sub write_mov_ai($$)
{
    my ($r, $imm) = @_;

    # movea.l #imm,%ar
    insn16(0x207c | ($r << 9));
    insn32($imm)
}

sub write_mov_ri($$)
{
    my ($r, $imm) = @_;

    if ($r < 8) {
        write_mov_di($r, $imm);
    } else {
        write_mov_ai($r - 8, $imm);
    }
}

# write random fp value of passed precision (1=single, 2=double, 3=extended)
sub write_random_fpreg_var($)
{
    my ($precision) = @_;
    my $randomize_low = 0;

    if ($precision != 1 && $precision != 2 && $precision != 3) {
        die "write_random_fpreg: invalid precision.\n";
    }

    my ($low, $high);
    my $r = rand(100);
    if ($r < 5) {
        # +-0 (5%)
        $low = $high = 0;
        $high |= 0x80000000 if (rand() < 0.5);
    } elsif ($r < 10) {
        # NaN (5%)
        # (plus a tiny chance of generating +-Inf)
        $randomize_low = 1;
        $high = rand(0xffffffff) | 0x7ff00000;
    } elsif ($r < 15) {
        # Infinity (5%)
        $low = 0;
        $high = 0x7ff00000;
        $high |= 0x80000000 if (rand() < 0.5);
    } elsif ($r < 30) {
        # Denormalized number (15%)
        # (plus tiny chance of +-0)
        $randomize_low = 1;
        $high = rand(0xffffffff) & ~0x7ff00000;
    } else {
        # Normalized number (70%)
        # (plus a small chance of the other cases)
        $randomize_low = 1;
        $high = rand(0xffffffff);
    }

    insn32($high);
    for (my $i = 1; $i < $precision; $i++) {
        if ($randomize_low) {
            $low = rand(0xffffffff);
        }
        insn32($low);
    }
}

sub write_random_fpdata()
{
    # fmove.x #random, %fpr
    for (my $r = 0; $r < 8; $r++) {
        insn32(0xf23c4800 | ($r << 7));
        write_random_fpreg_var(3); # extended
    }
}

sub write_set_fpcr($)
{
    my ($fpscr) = @_;
    # fmove.l #0.w,%fpcr
    insn32(0xf23c8800);
    insn32($fpscr);
}

sub write_random_regdata()
{
    # general purpose registers (except A6 (FP) and A7 (SP))
    for (my $i = 0; $i < 14; $i++) {
        write_mov_ri($i, rand(0xffffffff));
    }
    # initialize condition register
    write_mov_ccr(rand(0x10000));
}

my $OP_COMPARE = 0;        # compare registers
my $OP_TESTEND = 1;        # end of test, stop
my $OP_SETMEMBLOCK = 2;    # r0 is address of memory block (8192 bytes)
my $OP_GETMEMBLOCK = 3;    # add the address of memory block to r0
my $OP_COMPAREMEM = 4;     # compare memory block

sub write_random_register_data($)
{
    my ($fp_enabled) = @_;

    if ($fp_enabled) {
        # load floating point / SIMD registers
        write_random_fpdata();
    }

    write_random_regdata();
    write_risuop($OP_COMPARE);
}

sub eval_with_fields($$$$$) {
    # Evaluate the given block in an environment with Perl variables
    # set corresponding to the variable fields for the insn.
    # Return the result of the eval; we die with a useful error
    # message in case of syntax error.
    my ($insnname, $insn, $rec, $blockname, $block) = @_;
    my $evalstr = "{ ";
    for my $tuple (@{ $rec->{fields} }) {
        my ($var, $pos, $mask) = @$tuple;
        my $val = ($insn >> $pos) & $mask;
        $evalstr .= "my (\$$var) = $val; ";
    }
    $evalstr .= $block;
    $evalstr .= "}";
    my $v = eval $evalstr;
    if ($@) {
        print "Syntax error detected evaluating $insnname $blockname string:\n$block\n$@";
        exit(1);
    }
    return $v;
}

sub gen_one_insn($$)
{
    # Given an instruction-details array, generate an instruction
    my $constraintfailures = 0;

    INSN: while(1) {
        my ($forcecond, $rec) = @_;
        my $insn = int(rand(0xffffffff));
        my $insnname = $rec->{name};
        my $insnwidth = $rec->{width};
        my $fixedbits = $rec->{fixedbits};
        my $fixedbitmask = $rec->{fixedbitmask};
        my $constraint = $rec->{blocks}{"constraints"};
        my $post = $rec->{blocks}{"post"};
        my $memblock = $rec->{blocks}{"memory"};

        $insn &= ~$fixedbitmask;
        $insn |= $fixedbits;

        if (defined $constraint) {
            # user-specified constraint: evaluate in an environment
            # with variables set corresponding to the variable fields.
            my $v = eval_with_fields($insnname, $insn, $rec, "constraints", $constraint);
            if (!$v) {
                $constraintfailures++;
                if ($constraintfailures > 10000) {
                    print "10000 consecutive constraint failures for $insnname constraints string:\n$constraint\n";
                    exit (1);
                }
                next INSN;
            }
        }

        # OK, we got a good one
        $constraintfailures = 0;

        insn16($insn >> 16);
        if ($insnwidth == 32) {
            insn16($insn & 0xffff);
        }
        if (defined $post) {
            eval_with_fields($insnname, $insn, $rec, "post", $post);
        }

        return;
    }
}

my $lastprog;
my $proglen;
my $progmax;

sub progress_start($$)
{
    ($proglen, $progmax) = @_;
    $proglen -= 2; # allow for [] chars
    $| = 1;        # disable buffering so we can see the meter...
    print "[" . " " x $proglen . "]\r";
    $lastprog = 0;
}

sub progress_update($)
{
    # update the progress bar with current progress
    my ($done) = @_;
    my $barlen = int($proglen * $done / $progmax);
    if ($barlen != $lastprog) {
        $lastprog = $barlen;
        print "[" . "-" x $barlen . " " x ($proglen - $barlen) . "]\r";
    }
}

sub progress_end()
{
    print "[" . "-" x $proglen . "]\n";
    $| = 0;
}

sub write_test_code($)
{
    my ($params) = @_;

    my $condprob = $params->{ 'condprob' };
    my $fpscr = $params->{ 'fpscr' };
    my $numinsns = $params->{ 'numinsns' };
    my $fp_enabled = $params->{ 'fp_enabled' };
    my $outfile = $params->{ 'outfile' };

    my @pattern_re = @{ $params->{ 'pattern_re' } };
    my @not_pattern_re = @{ $params->{ 'not_pattern_re' } };
    my %insn_details = %{ $params->{ 'details' } };

    open_bin($outfile);

    # convert from probability that insn will be conditional to
    # probability of forcing insn to unconditional
    $condprob = 1 - $condprob;

    # TODO better random number generator?
    srand(0);

    # Get a list of the insn keys which are permitted by the re patterns
    my @keys = sort keys %insn_details;
    if (@pattern_re) {
        my $re = '\b((' . join(')|(',@pattern_re) . '))\b';
        @keys = grep /$re/, @keys;
    }
    # exclude any specifics
    if (@not_pattern_re) {
        my $re = '\b((' . join(')|(',@not_pattern_re) . '))\b';
        @keys = grep !/$re/, @keys;
    }
    if (!@keys) {
        print STDERR "No instruction patterns available! (bad config file or --pattern argument?)\n";
        exit(1);
    }
    print "Generating code using patterns: @keys...\n";
    progress_start(78, $numinsns);

    if (grep { defined($insn_details{$_}->{blocks}->{"memory"}) } @keys) {
        write_memblock_setup();
    }

    # memblock setup doesn't clean its registers, so this must come afterwards.
    write_random_register_data($fp_enabled);

    for my $i (1..$numinsns) {
        my $insn_enc = $keys[int rand (@keys)];
        my $forcecond = (rand() < $condprob) ? 1 : 0;
        gen_one_insn($forcecond, $insn_details{$insn_enc});
        write_risuop($OP_COMPARE);
        # Rewrite the registers periodically. This avoids the tendency
        # for the VFP registers to decay to NaNs and zeroes.
        if ($periodic_reg_random && ($i % 100) == 0) {
            write_random_register_data($fp_enabled);
        }
        progress_update($i);
    }
    write_risuop($OP_TESTEND);
    progress_end();
    close_bin();
}

1;
