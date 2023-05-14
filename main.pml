// worker index   -> aka workId
/////////// producerA = 0, producerB = 1, arbiter = 2, consumerA = 3, consumerB = 4
// resource index -> aka resId
/////////// bufferA = 0, bufferB = 1, bufferC = 0, bufferD = 0

int SEND_BATCH_SIZE            = 2 ;
int SENDING_SIZE_PER_LANE      = 10;
int DIFF_FAIRE_ALLOW           = 3 ;
int MAX_BUFFER_SIZE_GLOB       = 4 ;

typedef  PRODUCER_META {
    bool running;
    int amountPacketToSend;
    int produced;
};

typedef BUFFER_META {
    int  MAXBUFFER_SIZE;
    int  cur_size;
    bool inusing_worker[2]; //// idx 0 is producer_is in-use ///// idx 1 is arbiter_is_in-use
    int  selectTimes; /// times that arbiter select the buffer
};

typedef CONSUMER_META {
    bool isRunning;
    int  retrievedPacket;
    bool isHault;
};

typedef ARBITER_META{
    int  nextSending; /// 0 (bufferA) or 1 (bufferB)
    ///////// for capture value while selecting the next buffer to recruit
    int CAP_nextSending;
    bool CAP_fairNessHandle;
    bool CAP_IsDiffExceed;
    bool CAP_everyLaneReady;
    
}


PRODUCER_META     producer  [2];
BUFFER_META       sendBuffer[2];
BUFFER_META       recvBuffer[2];
CONSUMER_META     consumer  [2];
ARBITER_META      arbiter;


byte orchestor_pid;



proctype produce(int producerId){ /// 0 or 1 only

    do
        //////// case producer is dictate to run from arbiter
            ///////// it is ok to not atomic------v
        :: else -> {
            ///////////////////////////////////           v-------------- this value is signal by arbiter
            (sendBuffer[producerId].inusing_worker[0] == true) 
            do 
                                //////// check integrity of producer and buffer
                :: ( (producer[producerId].amountPacketToSend > 0) && (sendBuffer[producerId].cur_size < sendBuffer[producerId].MAXBUFFER_SIZE) ) -> 
                        {
                            ////// if ok then change the buffer size
                            producer[producerId].running = true;
                            atomic{
                                producer  [producerId].amountPacketToSend--;
                                producer  [producerId].produced++;
                                sendBuffer[producerId].cur_size++;
                                printf("producer %d send the data to buffer (%d)\n", producerId, producer  [producerId].produced)
                                producer[producerId].running = false;
                            }
                            
                        }
                :: ((producer[producerId].amountPacketToSend > 0) && (sendBuffer[producerId].cur_size >= sendBuffer[producerId].MAXBUFFER_SIZE)) -> 
                        {
                            /////////// if not but producer is able to produce we will loop back to wait signaling data from arbitee
                            atomic{
                                sendBuffer[producerId].inusing_worker[0] = false;  /// 0 means producer 1 means in-usin
                            }
                            goto doneRecruit;
                        }
                :: (producer[producerId].amountPacketToSend == 0) ->
                        {
                            //////////// producer is complete producer the packet let hault itself
                            atomic{
                                sendBuffer[producerId].inusing_worker[0] = false;  /// 0 means producer 1 means in-using
                            }
                            goto doneProducer;
                        }
            od
            doneRecruit: skip;
        }
    od
    doneProducer:skip

    printf("producer %d is stop\n", producerId)
}


proctype consume(int consumerId){
    do
        //////// case producer is dictate to run from arbiter
        :: else -> { 
                ///////////// lock the recv buffer for consuming
                atomic {
                    (!recvBuffer[consumerId].inusing_worker[1] && recvBuffer[consumerId].cur_size > 0)
                    recvBuffer[consumerId].inusing_worker[0]  = true;
                    consumer[consumerId].isRunning = true;
                }
        
            ///////////////////// update state of the size
            atomic{
                recvBuffer[consumerId].cur_size--;
                consumer  [consumerId].retrievedPacket++;
                consumer[consumerId].isRunning = false;
                printf("consumer %d consume the data to buffer (%d)\n", consumerId, consumer[consumerId].retrievedPacket)
            }
            //////// unlock recv buffer
            atomic{
            recvBuffer[consumerId].inusing_worker[0] = false;
            }
            /////// if consumer is finish, let hault the consumer
            if
                :: (consumer[consumerId].retrievedPacket >=  SENDING_SIZE_PER_LANE) -> goto doneConsumer;
                :: else -> skip
            fi
        }



    od
    doneConsumer:skip

    consumer[consumerId].isHault = true;
    printf("consumer %d is stop\n", consumerId)

}



//////////arbiter select PRIORITY
///// 2. listen to fairness checker
////////////////////case below is labeled as "faireness checker is allow two buffer for sending"
///// 3. use round rubin


////////  FYI faireness checker will check different packet size in recv buffer is not excceed the limit.
/////////////////// but, if there is one buffer full, the fireness checker will inform to select the free recv 
/////////////////// buffer lane instead by negless the packet differentiation

proctype orchestrate(){

    do
        :: true -> {
            /////////////////////// select which buffer should be proceed
            atomic{
                bool src0_producable     =  (producer[0].amountPacketToSend > 0);
                bool srcBuf0_proceedable =  sendBuffer[0].cur_size > 0;
                bool desBuf0_proceedable =  (recvBuffer[0].cur_size + SEND_BATCH_SIZE) <= recvBuffer[0].MAXBUFFER_SIZE;
                bool lane0_ready         =  srcBuf0_proceedable && desBuf0_proceedable;

                bool src1_producable     =  (producer[1].amountPacketToSend > 0);
                bool srcBuf1_proceedable =  sendBuffer[1].cur_size > 0;
                bool desBuf1_proceedable =  (recvBuffer[1].cur_size + SEND_BATCH_SIZE) <= recvBuffer[1].MAXBUFFER_SIZE;
                bool lane1_ready         =  srcBuf1_proceedable && desBuf1_proceedable;

                bool shouldStop  = !src0_producable && !srcBuf0_proceedable && !src1_producable && !srcBuf1_proceedable;

                //////////// faireness checking
                int fairSelect = 2;
                if 
                    :: (((recvBuffer[0].cur_size - recvBuffer[1].cur_size) > DIFF_FAIRE_ALLOW)   && lane1_ready) ->{
                        fairSelect = 1;
                    }
                    :: (((recvBuffer[1].cur_size - recvBuffer[0].cur_size) > DIFF_FAIRE_ALLOW)    && lane0_ready) ->{
                        fairSelect = 0;
                    }
                    :: else -> skip
                fi

                /////////  stat collecting
                arbiter.CAP_IsDiffExceed = (recvBuffer[0].cur_size - recvBuffer[1].cur_size) > DIFF_FAIRE_ALLOW ||
                                           (recvBuffer[1].cur_size - recvBuffer[0].cur_size) > DIFF_FAIRE_ALLOW;
                arbiter.CAP_everyLaneReady = lane0_ready && lane1_ready;
                ///////////////////////////////////////////////////////////////////////////////////////////////
                //////////select next buffer to select
                if
                    :: fairSelect == 2 ->{
                        //////// fairness checker does not explicitly select the buffer to go next
                            ////// then we need to select bigger inflight buffer that ready to send next
                        arbiter.CAP_fairNessHandle = false;
                        if
                            :: lane0_ready &&  lane1_ready && (sendBuffer[0].cur_size >= sendBuffer[1].cur_size) -> {
                                arbiter.nextSending = 0;
                            }
                            :: lane0_ready &&  lane1_ready && (sendBuffer[0].cur_size < sendBuffer[1].cur_size) -> {
                                arbiter.nextSending = 1;
                            }
                            :: lane0_ready && !lane1_ready ->{
                                arbiter.nextSending = 0;
                            }
                            :: !lane0_ready && lane1_ready ->{
                                arbiter.nextSending = 1;
                            }
                            :: shouldStop ->{
                                goto doneOrchestrate;
                            }
                            :: else -> {
                                arbiter.nextSending = -1;
                                //////////////////two lane can not send but still need to send
                            }
                        fi

                    }
                    :: else -> {
                        ////// for now we are sure that fairselect select the executable
                        arbiter.CAP_fairNessHandle = true;
                        /////////////////////////////////////////////////////////////////////////////
                        arbiter.nextSending = fairSelect;
                    }
                fi
                ///////////////////////////////////////////////////////////////////////////////////////////////////////////
                arbiter.CAP_nextSending = arbiter.nextSending
                SELECTING_TIME_QUANTUM_CAPTURE:    
            }
            //////////////// try to start producer if it down
            atomic{

                    if 
                        :: (producer[0].amountPacketToSend != 0) -> {
                            sendBuffer[0].inusing_worker[0] = true;
                        }
                        :: else->
                    fi

                    if 
                        :: (producer[1].amountPacketToSend != 0) -> {
                            sendBuffer[1].inusing_worker[0] = true;
                        }
                        :: else->
                    fi
            }

            if 
            :: arbiter.nextSending == -1 -> {
                    /////// in case, arbiter is not select who is the next transfer buffer, we need to wait until some buffers are sendable
                    ((sendBuffer[0].cur_size > 0 && (recvBuffer[0].cur_size + SEND_BATCH_SIZE) <= recvBuffer[0].MAXBUFFER_SIZE) || 
                     (sendBuffer[1].cur_size > 0 && (recvBuffer[1].cur_size + SEND_BATCH_SIZE) <= recvBuffer[1].MAXBUFFER_SIZE))
                     printf("arbiter early restart\n")
                    goto earlyRestart;
                }
            :: else -> skip;
            fi



            ///////////////////////////////////////////////////////////////////////////////////
            //////////////// select data to do next
            CHECK_ARBITER_SELECTION_REGION:
            printf("arbiter wait for testing\n")
            //////////////////////// wait for buffer is free and we will lock it
            ( (recvBuffer[arbiter.nextSending].inusing_worker[0] == false) && (sendBuffer[arbiter.nextSending].inusing_worker[0] == false));
            
            ///// lock the resource if inusing[0] is false, there is no thead to modify the variable therefore, we didn't need to make 2 resource occupy as atomic
            sendBuffer[arbiter.nextSending].inusing_worker[1] = true;
            recvBuffer[arbiter.nextSending].inusing_worker[1] = true;


            ////// send data
            atomic{                             
                int curSize      = sendBuffer[arbiter.nextSending].cur_size;
                int curBatchSize = 0;
                if 
                    :: (curSize < SEND_BATCH_SIZE) -> curBatchSize = curSize;
                    :: else -> curBatchSize = SEND_BATCH_SIZE;
                fi
                ////// increase data
                sendBuffer[arbiter.nextSending].cur_size = sendBuffer[arbiter.nextSending].cur_size - curBatchSize;
                recvBuffer[arbiter.nextSending].cur_size = recvBuffer[arbiter.nextSending].cur_size + curBatchSize;
                ////// stat keeping
                sendBuffer[arbiter.nextSending].selectTimes++;
                ////// unlock the resource
                sendBuffer[arbiter.nextSending].inusing_worker[1] = false;
                recvBuffer[arbiter.nextSending].inusing_worker[1] = false;
                printf("arbiter choose %d buffer for %d\n", arbiter.nextSending, curBatchSize)
            }
            ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
            earlyRestart: skip

        }  
    od
    doneOrchestrate:skip

    printf("arbiter is stop\n");

}

init {

    atomic{
    producer[0].amountPacketToSend = SENDING_SIZE_PER_LANE;
    producer[0].produced           = 0;
    /////////////////////////////////////////////////////////////
    producer[1].amountPacketToSend = SENDING_SIZE_PER_LANE;
    producer[1].produced           = 0;
    ////////////////////////////////////////////////////////////
    consumer[0].isRunning          = false;
    consumer[0].retrievedPacket    = 0;
    ////////////////////////////////////////////////////////////
    consumer[1].isRunning          = false;
    consumer[1].retrievedPacket    = 0;
    /////////////////////////////////////////////////////////////
    sendBuffer[0].MAXBUFFER_SIZE  = MAX_BUFFER_SIZE_GLOB;
    sendBuffer[1].MAXBUFFER_SIZE  = MAX_BUFFER_SIZE_GLOB;
    recvBuffer[0].MAXBUFFER_SIZE  = MAX_BUFFER_SIZE_GLOB;
    recvBuffer[1].MAXBUFFER_SIZE  = MAX_BUFFER_SIZE_GLOB;
    /////////////////////////////////////////////////////////////
    run produce(0);
    run produce(1);
    run consume(0);
    run consume(1);
    orchestor_pid = run orchestrate();
    }

}

ltl testing  {[] (true)}
ltl testing2 {[] (false)}

///// 1.

ltl bufferAtomic {[](   !( sendBuffer[0].inusing_worker[0] && sendBuffer[0].inusing_worker[1]) && 
                        !( sendBuffer[1].inusing_worker[0] && sendBuffer[1].inusing_worker[1])
                    )
                 }

///// 2.

ltl bufferCap    {
                 [](
                    sendBuffer[0].cur_size <= MAX_BUFFER_SIZE_GLOB &&
                    sendBuffer[1].cur_size <= MAX_BUFFER_SIZE_GLOB &&
                    recvBuffer[0].cur_size <= MAX_BUFFER_SIZE_GLOB &&
                    recvBuffer[1].cur_size <= MAX_BUFFER_SIZE_GLOB
                 )

}

///// 3.

ltl noStarvation {
                (<> (sendBuffer[0].selectTimes > 0 && sendBuffer[1].selectTimes > 0))
}

//// 4.
ltl notSelectIfDesBufferIsFull{
    [] ( (orchestrate[orchestor_pid]@CHECK_ARBITER_SELECTION_REGION) -> 
         ( recvBuffer[arbiter.nextSending].cur_size + SEND_BATCH_SIZE <= MAX_BUFFER_SIZE_GLOB )
        )
}


//// 5.

ltl producerStopWhenBufferIsFull{
    [] (
        (  (sendBuffer[0].cur_size == MAX_BUFFER_SIZE_GLOB) -> (!producer[0].running)) &&
        (  (sendBuffer[1].cur_size == MAX_BUFFER_SIZE_GLOB) -> (!producer[1].running))
       )
}


//// 6. 

ltl consumerAliveWhileBufferIsNotEmpty{
    [] (
        ((recvBuffer[0].cur_size != 0) -> (!consumer[0].isHault)) &&
        ((recvBuffer[1].cur_size != 0) -> (!consumer[1].isHault))
    )
}

///// 7.
ltl consumerPauseWhileBufferIsEmpty{
    [] (
        ((recvBuffer[0].cur_size == 0) -> (!consumer[0].isRunning)) &&
        ((recvBuffer[1].cur_size == 0) -> (!consumer[1].isRunning))
    )
}

///// 8.
ltl fairnessChecking{
    [] ( 
        (orchestrate[orchestor_pid]@SELECTING_TIME_QUANTUM_CAPTURE) -> 
        (   ( arbiter.CAP_everyLaneReady && arbiter.CAP_IsDiffExceed )  ->  
            ( arbiter.CAP_nextSending == (recvBuffer[1].cur_size < recvBuffer[0].cur_size))
        ))
}

///// 9.

ltl fairnessChecking2{
    [] ( orchestrate[orchestor_pid]@SELECTING_TIME_QUANTUM_CAPTURE ->
        (
            (!arbiter.CAP_fairNessHandle && arbiter.CAP_everyLaneReady) -> 
            (arbiter.CAP_nextSending == (sendBuffer[1].cur_size > sendBuffer[0].cur_size))
        )
     )
}

/////// 10.
ltl nodataLost{
    <> ( (producer[0].produced == consumer[0].retrievedPacket) && 
         (producer[1].produced == consumer[1].retrievedPacket)
        )
}