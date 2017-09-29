#!/bin/bash
NB=0
TO=1
while [[ $NB -lt 100 ]]; do
    predicates=$((2 + RANDOM % 9)) # ~[2,10]
    size1=$((10 + RANDOM % 41))    # ~[10,50]
    size2=$(($size1 + RANDOM % ($size1 + 1))) # ~[size1,2*size1]
    ppred1=`printf "%02d\n" $((1 + RANDOM % 25))` # ~(0,0.1)
    ppred2=`printf "%02d\n" $((10#$ppred1 + RANDOM % (2*10#$ppred1)))` # ~[ppred1,2*ppred1)
    pedge1=`printf "%02d\n" $((RANDOM % 11))` # ~(0,0.1)
    pedge2=`printf "%02d\n" $((10#$pedge1 + RANDOM % (4*10#$ppred1)))` # ~[pedge1,4*pedge1)
    python random_struct.py $size1 $predicates 0.$ppred1 0.$pedge1 > embed.struct
    python random_struct.py $size2 $predicates 0.$ppred2 0.$pedge2 >> embed.struct
    RS=`../../patools.native str2mzn embed.struct`
    R1=`timeout $TO ../../patools.native cembeds embed.struct`
    R2=`timeout $TO ../../patools.native uembeds embed.struct`
    R3=`timeout $TO ../../patools.native embeds embed.struct`
    if [[ "$RS" = "True" ]]; then
	R4=`timeout $TO ./run_or_tools.sh tmp.mzn`
	R5=`timeout $TO ./run_hcsp.sh tmp.mzn`
    else
	R4="False"
	R5="False"
    fi
    if [[ "$R1" = "" || "$R2" = "" || "$R3" = "" || "$R4" = "" || "$R5" = "" ]]; then
	bench=`printf "embed_bench/embed%03d.struct" $NB`
	cp embed.struct $bench
	if [ "$R1" = "" ]; then
	    echo "gecode timeout ($R2,$R3,$R4,$R5)"
	elif [ "$R2" = "" ]; then
	    echo "uembeds min_vals timeout ($R1,$R3,$R4,$R5)"
	elif [ "$R3" = "" ]; then
	    echo "uembeds max_confs timeout ($R1,$R2,$R4,$R5)"
	elif [ "$R4" = "" ]; then
	    echo "or_tools timeout ($R1,$R2,$R3,$R5)"
	else
	    echo "haifa_csp timeout ($R1,$R2,$R3,$R4)"
	fi
	NB=$(($NB + 1))
    else
	echo "Success: $R1"
    fi
done